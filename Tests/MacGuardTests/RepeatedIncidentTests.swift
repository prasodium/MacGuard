import Testing
import Foundation
@testable import MacGuardCore

/// Drives the real PowerMonitor -> state machine -> TheftResponseCoordinator chain through repeated
/// unplug/replug cycles, mirroring the wiring in AppCoordinator (which needs a GUI to instantiate).
@MainActor @Suite struct RepeatedIncidentTests {
    @MainActor final class Rig {
        var machine = GuardStateMachine()
        let alarm = MockAlarm(); let notifier = MockNotifier()
        let reader = ScriptedReader([snap(.connected)])
        let monitor: PowerMonitor
        let response: TheftResponseCoordinator
        var settings = AppSettings()
        var ignoredDisconnects = 0
        var responses: [Task<Void, Never>] = []

        init(delay: TimeInterval) {
            monitor = PowerMonitor(reader: reader, notifier: nil, confirmDelay: delay, pollInterval: 3600)
            response = TheftResponseCoordinator(alarm: alarm, locker: MockLock(), location: MockLoc(), notifier: notifier, store: nil, device: dev)
            settings.emailEnabled = true; settings.locationTimeout = 1; settings.followUpMode = .initialOnly
            monitor.onEvent = { [unowned self] e, _ in handle(e) }
        }
        func hooks() -> TheftResponseCoordinator.Hooks {
            .init(transition: { [unowned self] in machine.apply($0) }, update: { _ in }, log: { _, _, _ in },
                  monitoringState: { "healthy" }, localNotification: { _, _ in })
        }
        func handle(_ e: PowerEvent) {
            switch e {
            case .disconnectPending: machine.apply(.powerDisconnectPending)
            case .disconnectCancelled: machine.apply(.powerDisconnectCancelled)
            case .disconnectConfirmed:
                let can = [.armed, .powerTransitionPending, .monitoringDegraded].contains(machine.phase) || (machine.phase.isTheftFlow && machine.chargerReconnected)
                guard can else { ignoredDisconnects += 1; return }
                let inc = Incident()
                guard machine.apply(.theftConfirmed(incident: inc.id)) else { return }
                let s = settings, h = hooks()
                responses.append(Task { @MainActor in await self.response.respond(to: inc, settings: s, hooks: h) })
            case .reconnected:
                if machine.phase.isTheftFlow {
                    machine.apply(.chargerReconnected)
                    if settings.stopAlarmOnReconnect, alarm.isActive { alarm.stop() }
                }
            default: break
            }
        }
        func plug(_ p: ExternalPower) { reader.queue = [snap(p)]; monitor.refresh() }
        func settle() async { for t in responses { await t.value }; responses = [] }
    }

    @Test func alarmSoundsOnEveryUnplugNotJustTheFirst() async {
        let r = Rig(delay: 0)
        r.monitor.start()
        r.machine.apply(.requestArm); r.machine.apply(.armConfirmed)
        for cycle in 1...4 {
            r.plug(.disconnected); await r.settle()
            #expect(r.alarm.startCount == cycle, "cycle \(cycle): alarm must sound")
            #expect(r.alarm.isActive)
            r.plug(.connected)
            #expect(!r.alarm.isActive, "cycle \(cycle): alarm stops on reconnect")
        }
        #expect(r.ignoredDisconnects == 0); #expect(r.notifier.initial == 4)
    }

    @Test func worksWithConfirmationDelayToo() async {
        let r = Rig(delay: 0.1)
        r.monitor.start(); r.machine.apply(.requestArm); r.machine.apply(.armConfirmed)
        for cycle in 1...2 {
            r.plug(.disconnected)
            try? await Task.sleep(nanoseconds: 300_000_000)   // confirmation timer re-reads the (still unplugged) reader
            await r.settle()
            #expect(r.alarm.startCount == cycle)
            r.plug(.connected)
        }
    }

    @Test func manualSilenceThenReplugThenUnplugStillAlarms() async {
        let r = Rig(delay: 0); r.settings.stopAlarmOnReconnect = false
        r.monitor.start(); r.machine.apply(.requestArm); r.machine.apply(.armConfirmed)
        r.plug(.disconnected); await r.settle(); #expect(r.alarm.startCount == 1)
        r.alarm.stop()                       // owner silenced it manually
        r.plug(.connected)
        r.plug(.disconnected); await r.settle()
        #expect(r.alarm.startCount == 2 && r.alarm.isActive)
    }

    @Test func unplugWhileStillUnpluggedDoesNotRetrigger() async {
        let r = Rig(delay: 0)
        r.monitor.start(); r.machine.apply(.requestArm); r.machine.apply(.armConfirmed)
        r.plug(.disconnected); r.plug(.disconnected); r.plug(.disconnected); await r.settle()
        #expect(r.alarm.startCount == 1)
    }
}
