import SwiftUI
import MacGuardCore

struct OnboardingView: View {
    @EnvironmentObject var c: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Local private var step = 0
    @Local private var note = ""

    private let titles = ["Welcome", "Power monitoring", "Alarm test", "Screen lock", "Location", "Email", "Test notification", "Find My", "Arm protection"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Step \(step + 1) of \(titles.count): \(titles[step])").font(.headline).foregroundStyle(.secondary)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !note.isEmpty { Text(note).font(.callout).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }
            HStack {
                Button("Skip setup") { finish() }
                Spacer()
                if step > 0 { Button("Back") { step -= 1; note = "" } }
                if step < titles.count - 1 { Button("Next") { step += 1; note = "" }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                else { Button("Finish") { finish() }.buttonStyle(.borderedProminent) }
            }
        }.padding(24).frame(width: 560, height: 420)
    }

    private func finish() { c.settings.onboardingCompleted = true; dismiss() }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 8) {
                Text("MacGuard watches your charger. If it is unplugged while protection is armed, it sounds an alarm, asks macOS to lock the screen, and can email you the Mac's location.").font(.title3)
                Text("It cannot stop a thief from shutting down the Mac, force-quitting the app, or removing all power. Pair it with Find My.").foregroundStyle(.secondary)
            }
        case 1:
            VStack(alignment: .leading, spacing: 8) {
                Label(c.snapshot?.summary ?? "Power state unavailable", systemImage: c.snapshot == nil ? "xmark.octagon" : "checkmark.circle")
                Text("Battery: \(c.snapshot?.batteryPercent.map { "\($0)%" } ?? "n/a")")
                Text("Monitoring: \(c.health.level.rawValue) — \(c.health.detail)").foregroundStyle(.secondary)
            }
        case 2:
            VStack(alignment: .leading) { Button("Play alarm preview") { c.testAlarm() }; Text("Preview plays for about 2 seconds.").foregroundStyle(.secondary) }
        case 3:
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional: test the screen lock. Your display will turn off and, if your Mac requires a password immediately, you will need to sign in again.")
                Button("Lock my screen now (test)") {
                    Task { let r = await ScreenLockService().lock(); note = "Lock result: \(r.rawValue)"; c.log(.testEvent, "Screen lock test: \(r.rawValue)", test: true) }
                }
            }
        case 4:
            VStack(alignment: .leading, spacing: 8) {
                Text("Location lets alert emails include where the Mac is. It is requested only during incidents or tests. You can skip this; the alarm and lock still work.")
                Text("Status: \(c.locationProvider.authorization.rawValue)")
                Button("Allow location access") { c.locationProvider.requestAuthorization() }
            }
        case 5:
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Send email alerts", isOn: Binding(get: { c.settings.emailEnabled }, set: { c.settings.emailEnabled = $0; c.buildNotifier() }))
                TextField("Backend URL (https://…)", text: Binding(get: { c.settings.backendURL }, set: { c.settings.backendURL = $0 }))
                Text("Enter the enrollment token in Settings → Email. MacGuard never asks for an email password. Skipping leaves email alerts OFF.").font(.caption).foregroundStyle(.secondary)
            }
        case 6:
            VStack(alignment: .leading) {
                Text("A test email is sent only when you press the button.")
                Button("Send test email") { Task { await c.testEmail(); note = c.emailStatus } }.disabled(!c.settings.emailEnabled)
            }
        case 7:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(FindMyRecoveryGuide.steps.prefix(3).enumerated()), id: \.offset) { _, s in Text("• \(s.title)") }
                Button("OPEN FIND MY") { NSWorkspace.shared.open(FindMyRecoveryGuide.findMyURL) }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("Summary").font(.title3.bold())
                Label("Alarm: on", systemImage: "bell")
                Label("Screen lock: \(c.settings.autoScreenLock ? "on" : "OFF")", systemImage: "lock")
                Label("Location: \(c.settings.locationEnabled && c.locationProvider.authorization == .authorized ? "on" : "OFF / not authorized")", systemImage: "location")
                Label("Email: \(c.emailConfigured ? "on" : "OFF")", systemImage: "envelope")
                Text("Close this guide and press Arm Protection on the dashboard when the charger is connected.").foregroundStyle(.secondary)
            }
        }
    }
}
