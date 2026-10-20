import SwiftUI
import MacGuardCore

/// Label on the left, value + stepper on the right: every numeric setting lines up the same way.
private struct StepperRow: View {
    let title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, unit: String
    var format: String = "%.0f"
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("\(String(format: format, value.wrappedValue)) \(unit)").monospacedDigit().foregroundStyle(.secondary)
                Stepper("", value: value, in: range, step: step).labelsHidden()
            }
        }
    }
}

/// Right-aligned row for the buttons that act on the fields above them.
private struct ActionRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { HStack(spacing: 8) { Spacer(); content } }
}

struct SettingsView: View {
    @EnvironmentObject var c: AppCoordinator
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
        .frame(width: 560, height: 560)
        .confirmationDialog("Are you sure?", isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } })) {
            Button("Delete", role: .destructive) {
                if confirmClear == "locations" { c.clearLocationHistory() } else { c.clearEventLog() }
                confirmClear = nil
            }
        } message: { Text("This permanently deletes the selected local data.") }
    }

    private var s: Binding<AppSettings> { Binding(get: { c.settings }, set: { c.settings = $0 }) }

    // MARK: Alarm
    private var alarmTab: some View {
        Form {
            Section("Sound") {
                Picker("Alarm sound", selection: s.alarm.sound) { ForEach(SystemSoundPlayer.availableSounds, id: \.self) { Text($0).tag($0) } }
                ActionRow { Button("Preview") { c.testAlarm() } }
            }
            Section("Timing") {
                StepperRow(title: "Repeat every", value: s.alarm.repeatInterval, range: 0.5...30, step: 0.5, unit: "s", format: "%.1f")
                StepperRow(title: "Start after", value: s.alarm.initialDelay, range: 0...30, step: 1, unit: "s")
            }
            Section("Behavior") {
                Toggle("Raise volume to maximum", isOn: s.alarm.maximizeVolume)
                Toggle("Show a notification", isOn: s.alarm.showLocalNotification)
                Toggle("Stop when the charger is reconnected", isOn: s.stopAlarmOnReconnect)
            }
        }.formStyle(.grouped)
    }

    // MARK: Detection
    private var detectionTab: some View {
        Form {
            Section("When the charger is unplugged") {
                Picker("Confirm after", selection: s.disconnectDelay) {
                    Text("Immediately").tag(0.0); Text("1 second").tag(1.0); Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0)
                }.onChange(of: c.settings.disconnectDelay) { c.power.setConfirmDelay($0) }
                Toggle("Lock the screen", isOn: s.autoScreenLock)
            }
            Section("Startup") {
                Toggle("Start MacGuard at login", isOn: Binding(get: { c.settings.launchAtLogin }, set: { c.setLaunchAtLogin($0) }))
                Toggle("Resume protection after a restart", isOn: s.resumeArmedOnLaunch)
            }
        }.formStyle(.grouped)
    }

    // MARK: Email
    private var emailTab: some View {
        Form {
            Section("Status") {
                Toggle("Send email alerts", isOn: s.emailEnabled).onChange(of: c.settings.emailEnabled) { _ in c.buildNotifier() }
                LabeledContent("Brevo key", value: c.keySaved ? "Saved ✓" : "Not saved")
                LabeledContent("Sender", value: c.settings.senderEmail.isEmpty ? "Not set" : c.settings.senderEmail)
                LabeledContent("Alert address", value: c.settings.recipientEmail.isEmpty ? "Not verified" : "\(c.settings.recipientEmail) ✓")
                ActionRow { Button("Send test email") { Task { await c.testEmail() } }.disabled(!c.emailConfigured) }
            }

            Section("Brevo") {
                SecureField("API key", text: $brevoKey).help("Stored in your Mac's Keychain only.")
                TextField("Sender", text: $brevoFrom, prompt: Text("Address verified in Brevo"))
                ActionRow {
                    Button("Get a key…") { NSWorkspace.shared.open(URL(string: "https://app.brevo.com/settings/keys/api")!) }
                    if c.keySaved { Button("Remove key", role: .destructive) { Task { await c.removeBrevoKey() } } }
                    Button("Save") { Task { if await c.saveBrevo(apiKey: brevoKey, sender: brevoFrom) { brevoKey = "" } } }
                        .disabled(brevoKey.count < 10 || !brevoFrom.contains("@"))
                }
            }

            Section("Gmail for alerts") {
                TextField("Address", text: $gmail, prompt: Text("you@gmail.com"))
                ActionRow { Button("Send code") { Task { await c.sendVerificationCode(to: gmail) } }.disabled(!gmail.contains("@") || !c.keySaved) }
                if let p = c.pendingRecipient { LabeledContent("Code sent to", value: p) }
                TextField("Code", text: $code, prompt: Text("6 digits")).help("Alerts only go to an address after its code is verified.")
                ActionRow {
                    Button("Verify") { if c.confirmRecipient(email: gmail, code: code) { code = "" } }
                        .disabled(code.count != 6 || !gmail.contains("@"))
                }
            }

            if let m = c.configMessage {
                Section { Text(m).font(.callout) }
            }

            Section("Follow-ups") {
                Picker("Send", selection: s.followUpMode) { ForEach(FollowUpMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                if c.settings.followUpMode == .periodic {
                    StepperRow(title: "Every", value: Binding(get: { c.settings.followUpInterval / 60 }, set: { c.settings.followUpInterval = $0 * 60 }), range: 5...60, step: 5, unit: "min")
                    StepperRow(title: "For up to", value: Binding(get: { c.settings.followUpMaxDuration / 3600 }, set: { c.settings.followUpMaxDuration = $0 * 3600 }), range: 1...24, step: 1, unit: "h")
                }
                Toggle("Email when reconnected or disarmed", isOn: s.sendRecoveryNotice)
            }
        }
        .formStyle(.grouped)
        .onAppear { if brevoFrom.isEmpty { brevoFrom = c.settings.senderEmail } }
    }

    // MARK: Location
    private var permissionText: String {
        switch c.locationProvider.authorization {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not asked yet"
        case .restricted: return "Restricted"
        case .servicesDisabled: return "Location Services off"
        }
    }

    private var locationTab: some View {
        Form {
            Section("Permission") {
                Toggle("Include location in alerts", isOn: s.locationEnabled)
                LabeledContent("macOS permission", value: permissionText)
                ActionRow {
                    Button("Open Location Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                    }
                    Button("Allow") { c.locationProvider.requestAuthorization() }
                        .disabled(c.locationProvider.authorization != .notDetermined)
                }
            }
            Section("Accuracy") {
                Picker("Accuracy", selection: s.locationAccuracy) { ForEach(LocationAccuracySetting.allCases, id: \.self) { Text($0.title).tag($0) } }
                StepperRow(title: "Wait up to", value: s.locationTimeout, range: 5...60, step: 5, unit: "s")
            }
            Section("Saved location") {
                Toggle("Keep the last known location", isOn: s.keepLastKnownLocation)
                StepperRow(title: "Keep history for", value: Binding(get: { Double(c.settings.locationRetentionDays) }, set: { c.settings.locationRetentionDays = Int($0) }), range: 1...90, step: 1, unit: "days")
                LabeledContent("Last fix", value: c.lastLocation.map { "\($0.acquiredAt.formatted(date: .abbreviated, time: .shortened)) · ±\(Int($0.horizontalAccuracy ?? 0)) m" } ?? "None")
                ActionRow { Button("Clear history…", role: .destructive) { confirmClear = "locations" } }
            }
        }.formStyle(.grouped)
    }

    // MARK: Privacy
    private var privacyTab: some View {
        Form {
            Section("Event log") {
                StepperRow(title: "Keep for", value: Binding(get: { Double(c.settings.eventRetentionDays) }, set: { c.settings.eventRetentionDays = Int($0) }), range: 7...365, step: 7, unit: "days")
                ActionRow { Button("Clear log…", role: .destructive) { confirmClear = "events" } }
            }
        }.formStyle(.grouped)
    }

    // MARK: Tests
    private var testsTab: some View {
        Form {
            Section("Try it") {
                ActionRow {
                    Button("Alarm") { c.testAlarm() }
                    Button("Email") { Task { await c.testEmail() } }
                    Button("Location") { Task { locationResult = await c.testLocation() } }
                }
                if let r = locationResult { LabeledContent("Location", value: r).textSelection(.enabled) }
                LabeledContent("Email", value: c.emailStatus)
            }
            Section("Setup") {
                ActionRow { Button("Open setup guide") { c.showOnboarding = true } }
            }
        }.formStyle(.grouped)
    }
}
