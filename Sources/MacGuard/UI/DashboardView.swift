import SwiftUI
import MacGuardCore

struct DashboardView: View {
    @EnvironmentObject var c: AppCoordinator
    @Local private var locationResult: String?
    @Local private var showHistory = false
    @Local private var showFindMy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                if let b = c.banner { Banner(text: b, color: .orange) { c.banner = nil } }
                if let w = c.locationWarning { Banner(text: w, color: .yellow, dismiss: nil) }
                statusCard
                if c.machine.phase.isTheftFlow { incidentCard }
                grid
                controls
                limitations
            }.padding(24)
        }
        .sheet(isPresented: $c.showOnboarding) { OnboardingView().environmentObject(c) }
        .sheet(isPresented: $showHistory) { IncidentHistoryView().environmentObject(c).frame(minWidth: 560, minHeight: 440) }
        .sheet(isPresented: $showFindMy) { FindMyView().frame(minWidth: 520, minHeight: 440) }
        .confirmationDialog("Arm protection?", isPresented: $c.armPrompt, titleVisibility: .visible) {
            Button("Arm Protection") { c.confirmArm() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(c.snapshot?.summary ?? "Power state unknown"). If the charger is disconnected for \(Int(c.settings.disconnectDelay)) s, MacGuard will sound an alarm, request a screen lock\(c.settings.emailEnabled ? ", and email you" : "").")
        }
        .alert("Cannot arm", isPresented: Binding(get: { c.armError != nil }, set: { if !$0 { c.armError = nil } })) {
            Button("OK") { c.armError = nil }
        } message: { Text(c.armError ?? "") }
        .overlay(alignment: .bottom) { if let b = c.busy { Text(b).padding(8).background(.regularMaterial, in: Capsule()).padding() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.laptopcomputer").font(.system(size: 34)).foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text("MacGuard").font(.largeTitle.bold())
                Text("Smart Protection. Instant Alerts. Better Recovery.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        VStack(spacing: 10) {
            Image(systemName: c.statusSymbol).font(.system(size: 44)).foregroundStyle(c.statusColor)
            Text(c.statusLabel).font(.title.bold()).foregroundStyle(c.statusColor)
            if c.machine.phase == .monitoringDegraded { Text(c.health.detail).font(.callout) }
            if c.alarm.isActive { Button("Stop Alarm…") { Task { await c.silenceAlarm() } }.buttonStyle(.borderedProminent).tint(.red) }
            if c.machine.phase == .disarmed || c.machine.phase == .preparingToArm {
                Button("Arm Protection") { c.requestArm() }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            } else {
                Button("Disarm Protection…") { Task { await c.disarm() } }.controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity).padding().background(c.statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Protection status: \(c.statusLabel)")
    }

    private var incidentCard: some View {
        let i = c.incident
        return GroupBox("Current incident") {
            VStack(alignment: .leading, spacing: 4) {
                Text("ID \(i?.id.uuidString ?? "—")").font(.caption.monospaced())
                Label("Alarm: \(i?.alarm.rawValue ?? "—")", systemImage: "bell")
                Label("Screen lock: \(lockText(i?.screenLock))", systemImage: "lock")
                Label("Location: \(i?.locationOutcome?.rawValue ?? "pending")", systemImage: "location")
                Label("Email: \(i?.notification.rawValue ?? "—")", systemImage: "envelope")
                if c.machine.chargerReconnected { Label("Charger reconnected — Mac is NOT unlocked and protection stays on until you disarm.", systemImage: "bolt.fill") }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func lockText(_ s: ActionStatus?) -> String {
        switch s {
        case .succeeded: return "session locked (verified)"
        case .requestedUnverified: return "requested; lock not verified"
        case .some(let v): return v.rawValue
        case nil: return "—"
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
            StatCard(title: "Charger", value: c.snapshot?.summary ?? "Unknown", symbol: "bolt")
            StatCard(title: "Battery", value: c.snapshot?.batteryPercent.map { "\($0)%" } ?? "n/a", symbol: "battery.75percent")
            StatCard(title: "Monitoring", value: c.health.level.rawValue.capitalized + " — " + c.health.detail, symbol: "waveform.path.ecg")
            StatCard(title: "Location permission", value: c.locationProvider.authorization.rawValue, symbol: "location")
            StatCard(title: "Last location fix", value: c.lastLocation.map { $0.acquiredAt.formatted(date: .abbreviated, time: .shortened) + " (±\(Int($0.horizontalAccuracy ?? 0)) m)" } ?? "None", symbol: "mappin.and.ellipse")
            StatCard(title: "Email", value: c.emailConfigured ? "Configured" : (c.settings.emailEnabled ? "Not enrolled" : "Off"), symbol: "envelope")
            StatCard(title: "Last event", value: c.events.first.map { "\($0.type.title) — \($0.timestamp.formatted(date: .omitted, time: .shortened))" } ?? "No events yet", symbol: "clock")
            StatCard(title: "Notification", value: c.incident.map { $0.notification.rawValue } ?? c.emailStatus, symbol: "paperplane")
        }
    }

    private var controls: some View {
        GroupBox("Tools") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Test Alarm") { c.testAlarm() }
                    Button("Test Email") { Task { await c.testEmail() } }
                    Button("Test Location") { Task { locationResult = await c.testLocation() } }
                }
                if let r = locationResult { Text(r).font(.callout).textSelection(.enabled) }
                Text(c.emailStatus).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Event History") { showHistory = true }
                    Button("Find My Instructions") { showFindMy = true }
                    Button("Settings…") { openSettingsWindow() }
                    Button("Setup Guide") { c.showOnboarding = true }
                }
                Text("Test actions are recorded in the log and labelled TEST; they never create theft incidents.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var limitations: some View {
        Text("MacGuard is a deterrent and recovery aid. It cannot stop someone from shutting the Mac down, force-quitting the app, or removing all power, and the alarm may be inaudible if speakers are muted.")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

struct StatCard: View {
    let title: String, value: String, symbol: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct Banner: View {
    let text: String; let color: Color; let dismiss: (() -> Void)?
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.callout)
            Spacer()
            if let dismiss { Button("Dismiss", action: dismiss).buttonStyle(.borderless) }
        }.padding(10).background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
}
