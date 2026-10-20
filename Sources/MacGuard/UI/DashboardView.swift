import SwiftUI
import MacGuardCore

struct DashboardView: View {
    @EnvironmentObject var c: AppCoordinator
    @Local private var showHistory = false
    @Local private var showFindMy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if let b = c.banner { Banner(text: b, dismiss: { c.banner = nil }) }
                statusCard
                if c.machine.phase.isTheftFlow { incidentCard }
                tiles
                if let e = c.events.first(where: { !$0.isTest }) {
                    Text("Last: \(e.type.title) · \(e.timestamp.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $c.showOnboarding) { OnboardingView().environmentObject(c) }
        .sheet(isPresented: $showHistory) { IncidentHistoryView().environmentObject(c).frame(minWidth: 560, minHeight: 440) }
        .sheet(isPresented: $showFindMy) { FindMyView().frame(minWidth: 520, minHeight: 440) }
        .confirmationDialog("Arm protection?", isPresented: $c.armPrompt, titleVisibility: .visible) {
            Button("Arm") { c.confirmArm() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(c.snapshot?.summary ?? "") }
        .alert("Can't arm", isPresented: Binding(get: { c.armError != nil }, set: { if !$0 { c.armError = nil } })) {
            Button("OK") { c.armError = nil }
        } message: { Text(c.armError ?? "") }
        .overlay(alignment: .bottom) { if let b = c.busy { Text(b).padding(8).background(.regularMaterial, in: Capsule()).padding() } }
    }

    // MARK: Header
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.laptopcomputer").font(.title).foregroundStyle(.tint)
            Text("MacGuard").font(.title.bold())
            Spacer()
            IconButton(symbol: "clock.arrow.circlepath", label: "History") { showHistory = true }
            IconButton(symbol: "magnifyingglass.circle", label: "Find My") { showFindMy = true }
            IconButton(symbol: "gearshape.fill", label: "Settings") { openSettingsWindow() }
        }
    }

    // MARK: Status
    private var statusCard: some View {
        VStack(spacing: 14) {
            Image(systemName: c.statusSymbol).font(.system(size: 52)).foregroundStyle(c.statusColor)
            Text(c.statusLabel).font(.title.bold()).foregroundStyle(c.statusColor)
            if c.alarm.isActive {
                Button("Stop Alarm") { Task { await c.silenceAlarm() } }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            }
            if c.machine.phase == .disarmed || c.machine.phase == .preparingToArm {
                Button("Arm") { c.requestArm() }.buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            } else {
                Button("Disarm") { Task { await c.disarm() } }.controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 26)
        .background(c.statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
    }

    // MARK: Incident
    private var incidentCard: some View {
        let i = c.incident
        return VStack(alignment: .leading, spacing: 10) {
            Text("Incident").font(.headline)
            IncidentRow(symbol: "bell", title: "Alarm", value: c.alarm.isActive ? "On" : "Stopped", ok: true)
            IncidentRow(symbol: "lock", title: "Screen", value: lockText(i?.screenLock), ok: i?.screenLock == .succeeded)
            IncidentRow(symbol: "location", title: "Location", value: locationText(i), ok: i?.location != nil)
            IncidentRow(symbol: "envelope", title: "Email", value: emailText(i?.notification), ok: i?.notification == .accepted)
            if c.machine.chargerReconnected { IncidentRow(symbol: "bolt.fill", title: "Charger", value: "Back", ok: true) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private func lockText(_ s: ActionStatus?) -> String {
        switch s {
        case .succeeded: return "Locked"
        case .requestedUnverified: return "Requested"
        case .failed: return "Failed"
        case .skipped: return "Off"
        default: return "…"
        }
    }
    private func locationText(_ i: Incident?) -> String {
        if i?.location != nil { return "Found" }
        switch i?.locationOutcome {
        case nil: return "Looking…"
        case .disabledInSettings: return "Off"
        default: return "Not found"
        }
    }
    private func emailText(_ s: NotificationStatus?) -> String {
        switch s {
        case .accepted: return "Sent"
        case .queued, .retrying: return "Sending…"
        case .failed: return "Failed"
        case .disabled: return "Off"
        default: return "…"
        }
    }

    // MARK: Tiles
    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            let p = c.snapshot
            StatusTile(symbol: "bolt.fill", title: "Charger",
                       value: p.map { $0.external == .connected ? "Connected" : ($0.external == .disconnected ? "Unplugged" : "Unknown") } ?? "Unknown",
                       state: p?.external == .connected ? .good : (p?.external == .disconnected ? .warning : .off))
            StatusTile(symbol: "battery.75percent", title: "Battery", value: p?.batteryPercent.map { "\($0)%" } ?? "—",
                       state: (p?.batteryPercent ?? 100) < 20 ? .warning : .good)
            StatusTile(symbol: "location.fill", title: "Location", value: locationState.text, state: locationState.state) { openSettingsWindow() }
            StatusTile(symbol: "envelope.fill", title: "Email", value: emailState.text, state: emailState.state) { openSettingsWindow() }
        }
    }

    private var locationState: (text: String, state: TileState) {
        guard c.settings.locationEnabled else { return ("Off", .off) }
        switch c.locationProvider.authorization {
        case .authorized: return ("On", .good)
        case .notDetermined: return ("Allow", .warning)
        default: return ("Blocked", .warning)
        }
    }
    private var emailState: (text: String, state: TileState) {
        if !c.settings.emailEnabled { return ("Off", .off) }
        return c.emailConfigured ? ("Ready", .good) : ("Set up", .warning)
    }
}

// MARK: - Components

enum TileState { case good, warning, off
    var color: Color { switch self { case .good: return .green; case .warning: return .orange; case .off: return .gray } }
    var word: String { switch self { case .good: return "OK"; case .warning: return "Needs attention"; case .off: return "Off" } }
}

struct StatusTile: View {
    let symbol: String, title: String, value: String, state: TileState
    var action: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).frame(width: 28).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline)
            }
            Spacer(minLength: 0)
            Circle().fill(state.color).frame(width: 10, height: 10)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value). \(state.word)")
        if let action { Button(action: action) { content }.buttonStyle(.plain) } else { content }
    }
}

struct IncidentRow: View {
    let symbol: String, title: String, value: String, ok: Bool
    var body: some View {
        HStack {
            Image(systemName: symbol).frame(width: 24).foregroundStyle(.tint)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(ok ? .green : .secondary).bold()
        }
        .accessibilityElement(children: .combine)
    }
}

struct IconButton: View {
    let symbol: String, label: String, action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.title2).frame(width: 34, height: 34) }
            .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}

struct Banner: View {
    let text: String; let dismiss: (() -> Void)?
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            if let dismiss { Button("OK", action: dismiss).buttonStyle(.borderless) }
        }.padding(10).background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }
}
