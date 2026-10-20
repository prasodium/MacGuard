import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import MacGuardCore

@MainActor
final class AppCoordinator: ObservableObject {
    // Services
    let settingsStore: SettingsStore
    let store: SecurityEventStore?
    let alarm: AlarmManager
    let locationProvider = CoreLocationProvider()
    let locationService: LocationService
    let power: PowerMonitor
    let auth: OwnerAuthenticating = OwnerAuthenticationService()
    let secrets = KeychainStore()
    let connectivity = ConnectivityWatcher()
    private(set) var notifier: TheftNotificationService?
    private(set) var api: APIClient?
    private var response: TheftResponseCoordinator!

    // Published state
    @Published var machine = GuardStateMachine()
    @Published var snapshot: PowerSnapshot?
    @Published var health = MonitoringHealth()
    @Published var incident: Incident?
    @Published var events: [SecurityEvent] = []
    @Published var banner: String?
    @Published var armPrompt = false
    @Published var armError: String?
    @Published var emailStatus = "Not tested"
    @Published var backendInfo: BackendInfo?
    @Published var backendInfoError: String?
    @Published var configMessage: String?
    @Published var lastLocation: LocationRecord?
    @Published var busy: String?
    @Published var showOnboarding = false

    private var sleptAt: Date?
    private var heartbeat: Timer?
    private var restorePending = false
    private let device = DeviceInfo.current()

    var settings: AppSettings { get { settingsStore.settings } set { settingsStore.settings = newValue } }

    init() {
        settingsStore = SettingsStore()
        store = try? SecurityEventStore(path: SecurityEventStore.defaultURL())
        alarm = AlarmManager(player: SystemSoundPlayer())
        locationService = LocationService(provider: locationProvider, store: store)
        power = PowerMonitor(confirmDelay: settingsStore.settings.disconnectDelay)
        if store == nil { banner = "Local security log could not be opened; events will not be saved." }
        buildNotifier()
        response = TheftResponseCoordinator(alarm: alarm, locker: ScreenLockService(), location: locationService,
                                            notifier: notifier, store: store, device: device)
        wire()
        refreshEvents()
        lastLocation = try? store?.lastLocation()
        showOnboarding = !settings.onboardingCompleted
        restorePending = ((try? store?.value("armed")) ?? nil) != nil && settings.resumeArmedOnLaunch
        if let t = (try? store?.value("armed")) ?? nil, !settings.resumeArmedOnLaunch, !t.isEmpty {
            try? store?.setValue("armed", nil)
        }
        power.start()
        if let s = store { try? s.purgeEvents(olderThan: settings.eventRetentionDays); try? s.purgeLocations(olderThan: settings.locationRetentionDays) }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func buildNotifier() {
        guard let store, settings.emailEnabled, !settings.backendURL.isEmpty else { notifier = nil; api = nil; return }
        let c = APIClient(baseURL: settings.backendURL, secrets: secrets, allowLocalHTTP: true)
        api = c
        let n = TheftNotificationService(api: c, store: store)
        notifier = n
        Task { await n.setOnStatus { [weak self] id, status, msg in Task { @MainActor in self?.notificationChanged(id, status, msg) } } }
        connectivity.start { Task { await n.flush() } }
        Task { await n.flush() } // deliver anything queued before the last quit
    }

    // MARK: Wiring
    private func wire() {
        power.onEvent = { [weak self] e, s in self?.handle(e, s) }
        power.onHealth = { [weak self] h in self?.healthChanged(h) }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleptAt = Date() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }
        alarm.onChange = { [weak self] _ in self?.objectWillChange.send() }
    }

    private func hooks() -> TheftResponseCoordinator.Hooks {
        .init(transition: { [weak self] e in self?.apply(e) },
              update: { [weak self] i in if i.id == self?.machine.incidentID { self?.incident = i } },   // ignore late updates from an older incident
              log: { [weak self] t, r, id in self?.log(t, r, incident: id) },
              monitoringState: { [weak self] in self?.health.level.rawValue ?? "unknown" },
              localNotification: { [weak self] t, b in self?.postLocal(t, b) })
    }

    func apply(_ e: GuardEvent) { machine.apply(e) }

    func log(_ type: SecurityEventType, _ result: String, incident: UUID? = nil, test: Bool = false) {
        let ev = SecurityEvent(type: type, result: result, incidentID: incident, isTest: test)
        do { try store?.append(ev) } catch { banner = "Could not write to the local security log." }
        refreshEvents()
    }

    func refreshEvents() { events = (try? store?.events()) ?? [] }

    private func postLocal(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .defaultCritical
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: Power events
    private func handle(_ e: PowerEvent, _ s: PowerSnapshot?) {
        if let s { snapshot = s }
        switch e {
        case .baseline(let p):
            if restorePending { restorePending = false; restoreProtection(power: p) }
        case .disconnectPending:
            apply(.powerDisconnectPending)
        case .disconnectCancelled:
            apply(.powerDisconnectCancelled)
        case .disconnectConfirmed:
            let canTrigger = machine.phase == .armed || machine.phase == .powerTransitionPending || machine.phase == .monitoringDegraded
                || (machine.phase.isTheftFlow && machine.chargerReconnected)   // unplugged again after a reconnect
            guard canTrigger else {
                log(.chargerDisconnected, "Charger disconnected (protection off)"); return }
            startIncident()
        case .reconnected:
            log(.chargerReconnected, machine.phase.isTheftFlow ? "Charger reconnected; alarm and protection unchanged" : "Charger reconnected", incident: machine.incidentID)
            if machine.phase.isTheftFlow, var i = incident {
                apply(.chargerReconnected); i.chargerReconnectedAt = Date(); incident = i; try? store?.save(i)
                if settings.stopAlarmOnReconnect, alarm.isActive {
                    alarm.stop(); log(.alarmStopped, "Silenced because the charger was reconnected (setting)", incident: i.id)
                }
                if settings.sendRecoveryNotice, settings.emailEnabled {
                    Task { await notifier?.submitStatus(incidentID: i.id, code: "charger_reconnected", monitoring: health.level.rawValue) }
                }
            }
        case .readFailed, .readRecovered, .stateUnknown: break
        }
    }

    private func healthChanged(_ h: MonitoringHealth) {
        health = h
        if h.level == .degraded, [.armed, .powerTransitionPending].contains(machine.phase) {
            apply(.monitoringFailed); log(.monitoringInterrupted, h.detail)
        } else if h.level == .healthy, machine.phase == .monitoringDegraded {
            apply(.monitoringRecovered); log(.monitoringResumed, "Power monitoring recovered")
        }
    }

    private func didWake() {
        let gap = sleptAt.map { Date().timeIntervalSince($0) }
        if machine.isProtecting, let gap, gap > 5 { log(.monitoringGap, "Mac slept for \(Int(gap)) s; power state re-read on wake") }
        sleptAt = nil
        power.refresh()
    }

    // MARK: Incident
    private func startIncident() {
        let inc = Incident(powerBefore: .connected, powerAfter: .disconnected, batteryPercent: snapshot?.batteryPercent)
        guard machine.apply(.theftConfirmed(incident: inc.id)) else { return }
        incident = inc
        Task { await response.respond(to: inc, settings: settings, hooks: hooks()) }
    }

    private func notificationChanged(_ id: UUID, _ status: NotificationStatus, _ msg: String) {
        guard var i = incident, i.id == id else { return }
        i.notification = status; incident = i; try? store?.save(i)
        switch status {
        case .accepted: log(.emailAccepted, "Accepted by backend/provider (inbox delivery not confirmed)", incident: id); apply(.notificationSent)
        case .failed: log(.emailFailed, msg, incident: id)
        case .retrying, .queued: emailStatus = msg
        default: break
        }
    }

    // MARK: Arming
    var chargerConnected: Bool? { snapshot.map { $0.external == .connected } }

    func requestArm() {
        armError = nil
        guard let s = snapshot, s.external != .unknown, health.level == .healthy else {
            armError = "MacGuard cannot read the power state, so it cannot arm safely."; return }
        guard s.external == .connected else {
            armError = "The charger is not connected. Connect it first, then arm protection."; return }
        guard power.detector.pendingSince == nil else { armError = "Power state is changing; try again."; return }
        armPrompt = true
    }

    func confirmArm() {
        armPrompt = false
        guard machine.apply(.requestArm) else { return }
        power.setConfirmDelay(settings.disconnectDelay)
        guard power.detector.last == .connected else { apply(.armFailed); armError = "Power baseline unavailable."; return }
        apply(.armConfirmed)
        try? store?.setValue("armed", Data("1".utf8)); startHeartbeat()
        log(.protectionArmed, "Armed with charger connected; delay \(Int(settings.disconnectDelay)) s")
    }

    private func restoreProtection(power p: ExternalPower) {
        let last = ((try? store?.value("heartbeat")) ?? nil).flatMap { String(data: $0, encoding: .utf8) }.flatMap(Double.init)
        let gap = last.map { Date().timeIntervalSince1970 - $0 }
        if let gap, gap > 30 { log(.monitoringGap, "MacGuard was not running for about \(Int(gap)) s") }
        guard p == .connected, machine.apply(.requestArm) else {
            banner = "Protection was active before MacGuard stopped, but the charger is not connected. Reconnect it and arm again."
            try? store?.setValue("armed", nil); return }
        apply(.armConfirmed); startHeartbeat()
        log(.protectionRestored, "Resumed after restart (user setting: resume protection)")
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                try? self?.store?.setValue("heartbeat", Data(String(Date().timeIntervalSince1970).utf8))
            }
        }
        heartbeat?.tolerance = 10
    }

    func disarm() async {
        let needsAuth = machine.phase.isTheftFlow
        guard await auth.authenticate(reason: "Disarm MacGuard protection") else { banner = "Authentication was not completed; protection stays on."; return }
        _ = needsAuth
        alarm.stop(); response.cancelFollowUps()
        let id = machine.incidentID
        if machine.apply(.disarm(authorized: true)) {
            heartbeat?.invalidate(); try? store?.setValue("armed", nil)
            log(.protectionDisarmed, "Disarmed after owner authentication", incident: id)
            if let id, settings.emailEnabled { Task { await notifier?.submitStatus(incidentID: id, code: "protection_disarmed", monitoring: health.level.rawValue) } }
            incident = nil
        }
    }

    func silenceAlarm() async {
        guard await auth.authenticate(reason: "Stop the MacGuard alarm") else { return }
        alarm.stop(); log(.alarmStopped, "Silenced after owner authentication (protection still armed)", incident: machine.incidentID)
    }

    // MARK: Tests (never create permanent theft incidents)
    func testAlarm() { alarm.preview(settings: settings.alarm); log(.testEvent, "Alarm preview", test: true) }

    func testLocation() async -> String {
        busy = "Requesting location…"; defer { busy = nil }
        if locationProvider.authorization == .notDetermined { locationProvider.requestAuthorization(); try? await Task.sleep(nanoseconds: 1_500_000_000) }
        let a = await locationService.acquire(enabled: true, accuracy: settings.locationAccuracy, timeout: settings.locationTimeout, allowLastKnown: false)
        if let r = a.record { lastLocation = r }
        log(.testEvent, "Location test: \(a.outcome.rawValue)", test: true)
        guard let r = a.record else { return "No location (\(a.outcome.rawValue)). Authorization: \(a.authorization.rawValue)." }
        return String(format: "%.5f, %.5f (±%.0f m, %@)", r.latitude, r.longitude, r.horizontalAccuracy ?? -1, r.freshness.rawValue)
    }

    func testEmail() async {
        guard let n = notifier else { emailStatus = "Email is not configured."; return }
        busy = "Sending test email…"; defer { busy = nil }
        switch await n.sendTest(device: device) {
        case .success: emailStatus = "Test email accepted by the provider at \(Date().formatted(date: .omitted, time: .shortened)). Check your inbox."
            log(.testEvent, "Test email accepted", test: true)
        case .failure(let e): emailStatus = e.userMessage; log(.testEvent, "Test email failed: \(e.userMessage)", test: true)
        }
    }

    func enroll(token: String) async {
        buildNotifier()
        guard let api else { emailStatus = "Enter a valid backend URL first."; return }
        busy = "Enrolling…"; defer { busy = nil }
        do { try await api.enroll(token: token, deviceName: device.name); emailStatus = "Enrolled with the alert backend."; await refreshBackendInfo() }
        catch let e as APIError { emailStatus = e.userMessage } catch { emailStatus = "Enrollment failed." }
    }

    func refreshBackendInfo() async {
        backendInfo = nil; backendInfoError = nil
        guard let n = notifier else { backendInfoError = "Turn on email alerts and enter the backend URL first."; return }
        guard api?.isEnrolled == true else { backendInfoError = "This Mac is not enrolled yet. Enter an enrollment token."; return }
        busy = "Checking backend…"; defer { busy = nil }
        switch await n.fetchBackendInfo() {
        case .success(let i): backendInfo = i
        case .failure(let e): backendInfoError = e.userMessage
        }
    }

    // MARK: In-app email configuration (each change needs owner authentication)
    /// Sends the Brevo key to the backend once; nothing is kept on this Mac.
    func saveBrevo(apiKey: String, fromEmail: String) async -> Bool {
        configMessage = nil
        guard let n = notifier, api?.isEnrolled == true else { configMessage = "Enroll this Mac with your backend first."; return false }
        guard await auth.authenticate(reason: "Save the Brevo email key for MacGuard") else { configMessage = "Authentication was not completed."; return false }
        busy = "Saving key…"; defer { busy = nil }
        switch await n.saveProvider("brevo", apiKey: apiKey, fromEmail: fromEmail) {
        case .success: configMessage = "Brevo key verified and saved on your backend."; await refreshBackendInfo(); return true
        case .failure(let e): configMessage = e.userMessage; return false
        }
    }

    func sendVerificationCode(to email: String) async {
        configMessage = nil
        guard let n = notifier, api?.isEnrolled == true else { configMessage = "Enroll this Mac with your backend first."; return }
        guard await auth.authenticate(reason: "Change the MacGuard alert email address") else { configMessage = "Authentication was not completed."; return }
        busy = "Sending code…"; defer { busy = nil }
        switch await n.requestRecipientCode(email: email) {
        case .success: configMessage = "A 6-digit code was emailed to \(email). Enter it below. Alerts do not go there until it is verified."; await refreshBackendInfo()
        case .failure(let e): configMessage = e.userMessage
        }
    }

    func confirmRecipient(email: String, code: String) async -> Bool {
        guard let n = notifier else { return false }
        busy = "Verifying…"; defer { busy = nil }
        switch await n.confirmRecipient(email: email, code: code) {
        case .success:
            configMessage = "Verified. Alert emails will now go to \(email)."
            log(.testEvent, "Alert recipient verified and changed", test: true)
            await refreshBackendInfo(); return true
        case .failure(let e): configMessage = e.userMessage; return false
        }
    }

    var emailConfigured: Bool { settings.emailEnabled && api?.isEnrolled == true }

    // MARK: Login item
    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = on
        } catch { banner = "Could not change login item: \(error.localizedDescription)"; settings.launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    func clearLocationHistory() { try? store?.clearLocations(); lastLocation = nil }
    func clearEventLog() { try? store?.clearEvents(); refreshEvents() }

    // MARK: Presentation
    var statusLabel: String {
        switch machine.phase {
        case .disarmed: return "PROTECTION OFF"
        case .preparingToArm: return "PREPARING PROTECTION"
        case .armed, .powerTransitionPending: return "PROTECTED"
        case .monitoringDegraded: return "MONITORING DEGRADED"
        case .theftDetected, .alarmActive, .locationPending: return "ALARM ACTIVE"
        case .notificationPending: return alarm.isActive ? "ALARM ACTIVE" : "NOTIFICATION PENDING"
        case .notificationSent, .recoveryPending: return alarm.isActive ? "ALARM ACTIVE" : "INCIDENT RECORDED"
        }
    }
    var statusSymbol: String {
        switch machine.phase {
        case .disarmed: return "lock.open"
        case .preparingToArm: return "hourglass"
        case .armed, .powerTransitionPending: return "checkmark.shield.fill"
        case .monitoringDegraded: return "exclamationmark.triangle.fill"
        default: return "bell.and.waves.left.and.right.fill"
        }
    }
    var statusColor: Color {
        switch machine.phase {
        case .disarmed: return .secondary
        case .armed, .powerTransitionPending: return .green
        case .preparingToArm, .monitoringDegraded: return .orange
        default: return .red
        }
    }
    var locationWarning: String? {
        guard settings.locationEnabled, locationProvider.authorization != .authorized else { return nil }
        return "LOCATION UNAVAILABLE — authorization: \(locationProvider.authorization.rawValue)"
    }
}
