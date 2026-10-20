import SwiftUI
import MacGuardCore

struct SettingsView: View {
    @EnvironmentObject var c: AppCoordinator
    @Local private var token = ""
    @Local private var brevoKey = ""
    @Local private var brevoFrom = ""
    @Local private var gmail = ""
    @Local private var code = ""
    @Local private var locationResult: String?
    @Local private var confirmClear: String?

    var body: some View {
        TabView {
            alarmTab.tabItem { Label("Alarm", systemImage: "bell") }
            detectionTab.tabItem { Label("Detection", systemImage: "bolt") }
            emailTab.tabItem { Label("Email", systemImage: "envelope") }
            locationTab.tabItem { Label("Location", systemImage: "location") }
            privacyTab.tabItem { Label("Privacy", systemImage: "hand.raised") }
            testsTab.tabItem { Label("Tests", systemImage: "checkmark.seal") }
        }
        .frame(width: 620, height: 640).padding()
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
        }
    }

    private var detectionTab: some View {
        Form {
            Picker("Charger-disconnection delay", selection: s.disconnectDelay) {
                Text("Immediate").tag(0.0); Text("1 second").tag(1.0); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0)
            }.onChange(of: c.settings.disconnectDelay) { c.power.setConfirmDelay($0) }
            Toggle("Request a screen lock when theft is detected", isOn: s.autoScreenLock)
            Toggle("Start MacGuard when I log in", isOn: Binding(get: { c.settings.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
            Toggle("Resume protection automatically after MacGuard restarts", isOn: s.resumeArmedOnLaunch)
        }
    }

    private var emailTab: some View {
        ScrollView {
            Form {
                Toggle("Send email alerts", isOn: s.emailEnabled).onChange(of: c.settings.emailEnabled) { _ in c.buildNotifier() }

                Section("1. Connect this Mac to your backend") {
                    TextField("Backend URL (https://…)", text: s.backendURL)
                    SecureField("Enrollment token from your backend", text: $token)
                    Button("Enroll this Mac") { Task { await c.enroll(token: token); token = "" } }.disabled(token.isEmpty)
                    Text(c.emailStatus).font(.caption).foregroundStyle(.secondary)
                }

                Section("2. Email sending service: Brevo") {
                    if let i = c.backendInfo {
                        LabeledContent("Sending with", value: i.providerTitle)
                        LabeledContent("Sender", value: i.fromEmail ?? "not set")
                    }
                    SecureField("Brevo API key", text: $brevoKey).help("Sent once to your backend and kept there. Never stored on this Mac.")
                    TextField("Sender address verified in Brevo", text: $brevoFrom)
                    HStack {
                        Button("Save Brevo key") { Task { if await c.saveBrevo(apiKey: brevoKey, fromEmail: brevoFrom) { brevoKey = "" } } }
                            .disabled(brevoKey.count < 10 || !brevoFrom.contains("@"))
                        Button("Get a Brevo key…") { NSWorkspace.shared.open(URL(string: "https://app.brevo.com/settings/keys/api")!) }
                    }
                }

                Section("3. Where alerts are sent: your Gmail") {
                    if let i = c.backendInfo {
                        LabeledContent("Alert address", value: i.recipient.map { "\($0)" + (i.recipientVerified ? "  ✓ verified" : "") } ?? "none yet")
                        if let p = i.pendingRecipient { LabeledContent("Waiting for code", value: p) }
                    }
                    TextField("Gmail address for alerts", text: $gmail)
                    Button("Send verification code") { Task { await c.sendVerificationCode(to: gmail) } }.disabled(!gmail.contains("@"))
                    TextField("6-digit code from the email", text: $code).help("Alerts only go to an address after its code is verified.")
                    Button("Verify address") { Task { if await c.confirmRecipient(email: gmail, code: code) { code = "" } } }
                        .disabled(code.count != 6 || !gmail.contains("@"))
                }

                if let m = c.configMessage { Text(m).font(.callout).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }
                if let e = c.backendInfoError, c.backendInfo == nil { Text(e).font(.caption).foregroundStyle(.secondary) }

                Section("4. Check it") {
                    HStack {
                        Button("Check connection") { Task { await c.refreshBackendInfo() } }
                        Button("Send test email") { Task { await c.testEmail() } }
                            .disabled(c.backendInfo != nil && c.backendInfo?.recipientVerified != true)
                    }
                }

                Section("Follow-ups") {
                    Picker("Follow-ups", selection: s.followUpMode) { ForEach(FollowUpMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                    if c.settings.followUpMode == .periodic {
                        Stepper("Every \(Int(c.settings.followUpInterval / 60)) min", value: s.followUpInterval, in: 300...3600, step: 300)
                        Stepper("For up to \(Int(c.settings.followUpMaxDuration / 3600)) h", value: s.followUpMaxDuration, in: 3600...86400, step: 3600)
                    }
                    Toggle("Email me when the charger is reconnected or protection is disarmed", isOn: s.sendRecoveryNotice)
                }
            }.formStyle(.grouped)
        }
        .task { if c.backendInfo == nil, c.api?.isEnrolled == true { await c.refreshBackendInfo() } }
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
        }
    }

    private var testsTab: some View {
        Form {
            Section("Try the protections") {
                HStack {
                    Button("Test Alarm") { c.testAlarm() }
                    Button("Test Email") { Task { await c.testEmail() } }
                    Button("Test Location") { Task { locationResult = await c.testLocation() } }
                }
                if let r = locationResult { Text(r).font(.callout).textSelection(.enabled) }
                Text(c.emailStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("Setup") {
                Button("Open the setup guide") { c.showOnboarding = true }
            }
        }.formStyle(.grouped)
    }

    private var privacyTab: some View {
        Form {
            Stepper("Keep event log \(c.settings.eventRetentionDays) days", value: s.eventRetentionDays, in: 7...365, step: 7)
            Button("Clear event log…", role: .destructive) { confirmClear = "events" }
        }
    }
}
