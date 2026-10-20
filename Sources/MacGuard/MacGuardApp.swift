import SwiftUI
import AppKit
import MacGuardCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: AppCoordinator?
    // Closing the dashboard must not stop monitoring: the app lives on in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = coordinator, c.machine.isProtecting else { return .terminateNow }
        Task { @MainActor in
            let ok = await c.auth.authenticate(reason: "Quit MacGuard while protection is active")
            NSApp.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }
}

@main
struct MacGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var coordinator: AppCoordinator

    init() {
        if CommandLine.arguments.contains("--self-check") { SelfCheck.runAndExit() }
        _coordinator = StateObject(wrappedValue: AppCoordinator())
    }

    var body: some Scene {
        Window("MacGuard", id: "main") {
            DashboardView()
                .environmentObject(coordinator)
                .frame(minWidth: 640, minHeight: 640)
                .onAppear {
                    delegate.coordinator = coordinator
                    if CommandLine.arguments.contains("--open-settings") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openSettingsWindow() }
                    }
                }
        }
        Settings { SettingsView().environmentObject(coordinator) }
        MenuBarExtra {
            MenuBarContent().environmentObject(coordinator)
        } label: {
            Image(systemName: coordinator.statusSymbol)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var c: AppCoordinator
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(c.statusLabel)
        Divider()
        Button("Open MacGuard") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Settings…") { openSettingsWindow() }
        if c.alarm.isActive { Button("Stop Alarm…") { Task { await c.silenceAlarm() } } }
        if c.machine.phase == .disarmed { Button("Arm") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); c.requestArm() } }
        else { Button("Disarm") { Task { await c.disarm() } } }
        Divider()
        Button("Quit MacGuard") { NSApp.terminate(nil) }
    }
}
