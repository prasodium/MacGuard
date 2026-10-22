import SwiftUI
import Combine
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
    let mailConfig = MailConfig()
    private(set) var mailer: BrevoMailer?
    private(set) var verifier: RecipientVerifier?
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
    @Published var keySaved = false
    @Published var pendingRecipient: String?
    @Published var configMessage: String?
    @Published var lastLocation: LocationRecord?
    @Published var busy: String?
    @Published var showOnboarding = false

    private var cancellables = Set<AnyCancellable>()
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
        // Views observe the coordinator, but settings live in SettingsStore: forward its changes so every
        // setting (steppers, pickers, toggles) refreshes the UI immediately instead of on the next redraw.
        settingsStore.$settings.sink { [weak self] s in self?.mailConfig.minInterval = s.emailMinInterval }.store(in: &cancellables)
        settingsStore.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        if store == nil { banner = "Can't save the event log." }
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

    /// (Re)creates the Brevo mailer, recipient verifier and notifier from current settings.
    func buildNotifier() {
        mailConfig.sender = settings.senderEmail
        mailConfig.minInterval = settings.emailMinInterval
        mailConfig.recipient = settings.recipientEmail.isEmpty ? nil : settings.recipientEmail
        guard let store else { return }
        let m = mailer ?? BrevoMailer(secrets: secrets, config: mailConfig)
        mailer = m
        verifier = RecipientVerifier(store: store, mailer: m)
        keySaved = m.hasKey; pendingRecipient = verifier?.pendingEmail
        guard settings.emailEnabled else { notifier = nil; return }
        let cfg = mailConfig
        let n = TheftNotificationService(mailer: m, store: store, recipient: { cfg.recipient }, minInterval: { cfg.minInterval })
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
        do { try store?.append(ev) } catch { banner = "Can't save the event log." }
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
        case .accepted: log(.emailAccepted, "Accepted by Brevo (inbox delivery not confirmed)", incident: id); apply(.notificationSent)
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
            armError = "Can't read the power state."; return }
        guard s.external == .connected else {
            armError = "Plug in the charger first."; return }
        guard power.detector.pendingSince == nil else { armError = "Try again in a moment."; return }
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
            banner = "Protection was on before a restart. Plug in the charger and arm again."
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
        guard await auth.authenticate(reason: "Disarm MacGuard protection") else { banner = "Not confirmed. Protection stays on."; return }
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
        guard let n = notifier else { emailStatus = "Turn on email alerts first."; return }
        busy = "Sending test email…"; defer { busy = nil }
        switch await n.sendTest(device: device) {
        case .success: emailStatus = "Test email sent. Check your inbox."
            log(.testEvent, "Test email accepted", test: true)
        case .failure(let e): emailStatus = e.userMessage; log(.testEvent, "Test email failed: \(e.userMessage)", test: true)
        }
    }

    // MARK: Email configuration (each change needs owner authentication)
    var emailConfigured: Bool { settings.emailEnabled && keySaved && !settings.senderEmail.isEmpty && !settings.recipientEmail.isEmpty }

    /// Checks the key with Brevo, then keeps it in the Keychain (nowhere else).
    func saveBrevo(apiKey: String, sender: String) async -> Bool {
        configMessage = nil
        guard await auth.authenticate(reason: "Save the Brevo email key for MacGuard") else { configMessage = "Not confirmed."; return false }
        guard RecipientVerifier.normalized(sender) != nil else { configMessage = "Enter a valid sender address."; return false }
        busy = "Checking key…"; defer { busy = nil }
        let previous = secrets.get(BrevoMailer.keyAccount)
        settings.senderEmail = sender.trimmingCharacters(in: .whitespaces)
        buildNotifier()
        guard let m = mailer, m.saveKey(apiKey) else { configMessage = "Could not store the key in the Keychain."; return false }
        do { try await m.verifyKey() }
        catch {
            if let previous { _ = secrets.set(BrevoMailer.keyAccount, previous) } else { m.removeKey() }
            keySaved = m.hasKey
            configMessage = APIError.message(for: error); return false
        }
        keySaved = true; configMessage = "Key saved."
        return true
    }

    func removeBrevoKey() async {
        guard await auth.authenticate(reason: "Remove the Brevo email key") else { return }
        mailer?.removeKey(); keySaved = false; configMessage = "Brevo key removed."
    }

    func sendVerificationCode(to email: String) async {
        configMessage = nil
        guard mailer?.isConfigured == true else { configMessage = "Save the Brevo key first."; return }
        guard await auth.authenticate(reason: "Change the MacGuard alert email address") else { configMessage = "Not confirmed."; return }
        busy = "Sending code…"; defer { busy = nil }
        do {
            try await verifier?.requestCode(email: email)
            pendingRecipient = verifier?.pendingEmail
            configMessage = "Code sent to \(email)."
        } catch let e as VerificationError { configMessage = e.userMessage }
        catch { configMessage = APIError.message(for: error) }
    }

    func confirmRecipient(email: String, code: String) -> Bool {
        do {
            let verified = try verifier?.confirm(email: email, code: code) ?? ""
            let previous = settings.recipientEmail
            settings.recipientEmail = verified; buildNotifier()
            configMessage = "Verified. Alerts go to \(verified)."
            log(.testEvent, "Alert recipient verified and changed", test: true)
            if !previous.isEmpty, previous != verified, let m = mailer {   // tell the old address, so an unwanted change is visible
                let r = EmailTemplates.recipientChanged(newAddress: verified)
                Task { _ = try? await m.send(OutgoingMail(to: previous, subject: r.subject, html: r.html, text: r.text)) }
            }
            return true
        } catch let e as VerificationError { configMessage = e.userMessage; return false }
        catch { configMessage = "Verification failed."; return false }
    }

    // MARK: Login item
    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = on
        } catch { banner = "Can't change the login item."; settings.launchAtLogin = SMAppService.mainApp.status == .enabled }
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
