import SwiftUI
import MacGuardCore

struct OnboardingView: View {
    @EnvironmentObject var c: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @Local private var step = 0
    @Local private var note = ""

    private let titles = ["Welcome", "Charger", "Alarm", "Screen lock", "Location", "Email", "Test email", "Find My", "Arm"]
    private let symbols = ["lock.laptopcomputer", "bolt.fill", "bell.fill", "lock.fill", "location.fill", "envelope.fill", "paperplane.fill", "magnifyingglass.circle.fill", "checkmark.shield.fill"]

    var body: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(step + 1), total: Double(titles.count)).accessibilityLabel("Step \(step + 1) of \(titles.count)")
            Image(systemName: symbols[step]).font(.system(size: 44)).foregroundStyle(.tint).padding(.top, 8)
            Text(titles[step]).font(.title2.bold())
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !note.isEmpty { Text(note).font(.callout).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }
            HStack {
                Button("Skip") { finish() }
                Spacer()
                if step > 0 { Button("Back") { step -= 1; note = "" } }
                if step < titles.count - 1 { Button("Next") { step += 1; note = "" }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
                else { Button("Done") { finish() }.buttonStyle(.borderedProminent) }
            }
        }.padding(24).frame(width: 480, height: 400)
    }

    private func finish() { c.settings.onboardingCompleted = true; dismiss() }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: line("Unplug the charger while armed and MacGuard sounds an alarm and locks the screen.")
        case 1:
            VStack(spacing: 6) {
                Text(c.snapshot?.summary ?? "Can't read the charger").font(.headline)
                Text("Battery \(c.snapshot?.batteryPercent.map { "\($0)%" } ?? "—")").foregroundStyle(.secondary)
            }
        case 2: Button("Play alarm") { c.testAlarm() }
        case 3:
            VStack(spacing: 8) {
                Button("Lock my screen now") {
                    Task { let r = await ScreenLockService().lock(); note = r == .succeeded ? "Locked." : "Lock result: \(r.rawValue)"; c.log(.testEvent, "Screen lock test: \(r.rawValue)", test: true) }
                }
                Text("Optional").font(.caption).foregroundStyle(.secondary)
            }
        case 4:
            VStack(spacing: 8) {
                Text(c.locationProvider.authorization == .authorized ? "Allowed" : "Not allowed yet").font(.headline)
                Button("Allow location") { c.locationProvider.requestAuthorization() }
            }
        case 5:
            VStack(spacing: 10) {
                Toggle("Send email alerts", isOn: Binding(get: { c.settings.emailEnabled }, set: { c.settings.emailEnabled = $0; c.buildNotifier() })).toggleStyle(.switch)
                Button("Open Settings → Email") { openSettingsWindow() }
            }
        case 6:
            Button("Send test email") { Task { await c.testEmail(); note = c.emailStatus } }.disabled(!c.emailConfigured)
        case 7:
            Button("Open Find My") { NSWorkspace.shared.open(FindMyRecoveryGuide.findMyURL) }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Label("Alarm", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label(c.settings.autoScreenLock ? "Screen lock" : "Screen lock off", systemImage: c.settings.autoScreenLock ? "checkmark.circle.fill" : "xmark.circle")
                Label(c.locationProvider.authorization == .authorized ? "Location" : "Location off", systemImage: c.locationProvider.authorization == .authorized ? "checkmark.circle.fill" : "xmark.circle")
                Label(c.emailConfigured ? "Email" : "Email off", systemImage: c.emailConfigured ? "checkmark.circle.fill" : "xmark.circle")
            }
        }
    }

    private func line(_ t: String) -> some View { Text(t).font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary) }
}
