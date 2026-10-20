import SwiftUI
import MacGuardCore

struct SettingsView: View {
    @EnvironmentObject var c: AppCoordinator
    @Local private var token = ""
    @Local private var confirmClear: String?

    var body: some View {
        TabView {
            alarmTab.tabItem { Label("Alarm", systemImage: "bell") }
            detectionTab.tabItem { Label("Detection", systemImage: "bolt") }
            emailTab.tabItem { Label("Email", systemImage: "envelope") }
            locationTab.tabItem { Label("Location", systemImage: "location") }
            privacyTab.tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 560, height: 460).padding()
        .confirmationDialog("Are you sure?", isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } })) {
            Button("Delete", role: .destructive) {
                if confirmClear == "locations" { c.clearLocationHistory() } else { c.clearEventLog() }
                confirmClear = nil
            }
        } message: { Text("This permanently deletes the selected local data.") }
    }

    private var s: Binding<AppSettings> { Binding(get: { c.settings }, set: { c.settings = $0 }) }

    private var alarmTab: some View {
        Form {
            Picker("Alarm sound", selection: s.alarm.sound) { ForEach(SystemSoundPlayer.availableSounds, id: \.self) { Text($0) } }
            Stepper("Repeat every \(String(format: "%.1f", c.settings.alarm.repeatInterval)) s", value: s.alarm.repeatInterval, in: 0.5...30, step: 0.5)
            Stepper("Initial delay \(String(format: "%.0f", c.settings.alarm.initialDelay)) s", value: s.alarm.initialDelay, in: 0...30)
            Toggle("Raise volume to maximum when the alarm starts", isOn: s.alarm.maximizeVolume)
            Toggle("Show a local notification with the alarm", isOn: s.alarm.showLocalNotification)
            Toggle("Keep alarming after the screen locks", isOn: s.alarm.continueAfterLock)
            Button("Preview alarm") { c.testAlarm() }
            Text("The alarm can be stopped only after owner authentication. It may be inaudible if speakers are muted or audio is routed elsewhere, and cannot sound during sleep, shutdown or if the app is force-quit.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var detectionTab: some View {
        Form {
            Picker("Charger-disconnection delay", selection: s.disconnectDelay) {
                Text("Immediate").tag(0.0); Text("1 second").tag(1.0); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0)
            }.onChange(of: c.settings.disconnectDelay) { c.power.setConfirmDelay($0) }
            Text("Longer delays reduce false alarms from a loose cable but delay the response.").font(.caption).foregroundStyle(.secondary)
            Toggle("Request a screen lock when theft is detected", isOn: s.autoScreenLock)
            Text("Locking works by sleeping the display; macOS must be set to require a password immediately (System Settings → Lock Screen). MacGuard reports whether it could verify the lock.").font(.caption).foregroundStyle(.secondary)
            Toggle("Start MacGuard when I log in", isOn: Binding(get: { c.settings.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
            Text("This starts after you log in. MacGuard cannot monitor before login or while the Mac is shut down.").font(.caption).foregroundStyle(.secondary)
            Toggle("Resume protection automatically after MacGuard restarts", isOn: s.resumeArmedOnLaunch)
        }
    }

    private var emailTab: some View {
        Form {
            Toggle("Send email alerts", isOn: s.emailEnabled).onChange(of: c.settings.emailEnabled) { _ in c.buildNotifier() }
            TextField("Backend URL (https://…)", text: s.backendURL)
            SecureField("Enrollment token from your backend", text: $token)
            HStack {
                Button("Enroll this Mac") { Task { await c.enroll(token: token); token = "" } }.disabled(token.isEmpty)
                Button("Send test email") { Task { await c.testEmail() } }
            }
            Text(c.emailStatus).font(.caption)
            Text("The recipient is fixed on the backend by the operator. The app never sees your email password or any email-provider key.").font(.caption).foregroundStyle(.secondary)
            Picker("Follow-ups", selection: s.followUpMode) { ForEach(FollowUpMode.allCases, id: \.self) { Text($0.title).tag($0) } }
            if c.settings.followUpMode == .periodic {
                Stepper("Every \(Int(c.settings.followUpInterval / 60)) min", value: s.followUpInterval, in: 300...3600, step: 300)
                Stepper("For up to \(Int(c.settings.followUpMaxDuration / 3600)) h", value: s.followUpMaxDuration, in: 3600...86400, step: 3600)
            }
            Toggle("Email me when the charger is reconnected or protection is disarmed", isOn: s.sendRecoveryNotice)
        }
    }

    private var locationTab: some View {
        Form {
            Toggle("Include location in alerts", isOn: s.locationEnabled)
            Text("Authorization: \(c.locationProvider.authorization.rawValue)")
            HStack {
                Button("Request permission") { c.locationProvider.requestAuthorization() }
                Button("Open Location Services settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
            }
            Picker("Accuracy", selection: s.locationAccuracy) { ForEach(LocationAccuracySetting.allCases, id: \.self) { Text($0.title).tag($0) } }
            Stepper("Wait up to \(Int(c.settings.locationTimeout)) s for a fix", value: s.locationTimeout, in: 5...60, step: 5)
            Toggle("Keep last known location locally", isOn: s.keepLastKnownLocation)
            Stepper("Keep location history \(c.settings.locationRetentionDays) days", value: s.locationRetentionDays, in: 1...90)
            Text("Last fix: " + (c.lastLocation.map { "\($0.acquiredAt.formatted()) ±\(Int($0.horizontalAccuracy ?? 0)) m" } ?? "none"))
            Button("Clear location history…", role: .destructive) { confirmClear = "locations" }
            Text("Location is requested only when you test it or when an incident occurs; never continuously.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var privacyTab: some View {
        Form {
            Stepper("Keep event log \(c.settings.eventRetentionDays) days", value: s.eventRetentionDays, in: 7...365, step: 7)
            Button("Clear event log…", role: .destructive) { confirmClear = "events" }
            Text("Data is stored only on this Mac in ~/Library/Application Support/MacGuard (owner-only permissions). Secrets live in the Keychain.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
