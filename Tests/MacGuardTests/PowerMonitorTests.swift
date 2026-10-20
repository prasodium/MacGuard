import Testing
import Foundation
@testable import MacGuardCore

func snap(_ p: ExternalPower, pct: Int? = 80, charged: Bool? = nil) -> Result<PowerSnapshot, Error> {
    .success(PowerSnapshot(external: p, batteryPercent: pct, isCharging: p == .connected && charged != true, isFullyCharged: charged))
}
let t0 = Date(timeIntervalSince1970: 1_000_000)
func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

@Suite struct PowerDetectorTests {
    @Test func connectedBaselineThenImmediateDisconnect() {
        var d = PowerTransitionDetector(confirmDelay: 0)
        #expect(d.ingest(snap(.connected), now: at(0)) == [.baseline(.connected)])
        #expect(d.ingest(snap(.disconnected), now: at(1)) == [.disconnectConfirmed(at: at(1))])
    }
    @Test func startingOnBatteryNeverAlarms() {
        var d = PowerTransitionDetector(confirmDelay: 0)
        #expect(d.ingest(snap(.disconnected), now: at(0)) == [.baseline(.disconnected)])
        #expect(d.ingest(snap(.disconnected), now: at(5)).isEmpty)
    }
    @Test func duplicateNotificationsProduceOneConfirmation() {
        var d = PowerTransitionDetector(confirmDelay: 0)
        _ = d.ingest(snap(.connected), now: at(0))
        let first = d.ingest(snap(.disconnected), now: at(1))
        let second = d.ingest(snap(.disconnected), now: at(1.01))
        #expect(first.count == 1); #expect(second.isEmpty)
    }
    @Test func delayedConfirmationRequiresStillDisconnected() {
        var d = PowerTransitionDetector(confirmDelay: 3)
        _ = d.ingest(snap(.connected), now: at(0))
        #expect(d.ingest(snap(.disconnected), now: at(1)) == [.disconnectPending(since: at(1))])
        #expect(d.ingest(snap(.disconnected), now: at(2)).isEmpty)
        #expect(d.ingest(snap(.disconnected), now: at(4.1)) == [.disconnectConfirmed(at: at(1))])
    }
    @Test func transientDisconnectIsCancelled() {
        var d = PowerTransitionDetector(confirmDelay: 3)
        _ = d.ingest(snap(.connected), now: at(0))
        _ = d.ingest(snap(.disconnected), now: at(1))
        #expect(d.ingest(snap(.connected), now: at(2)) == [.disconnectCancelled])
        #expect(d.ingest(snap(.disconnected), now: at(10)) == [.disconnectPending(since: at(10))])
    }
    @Test func fullyChargedConnectedIsStillConnected() {
        var d = PowerTransitionDetector(confirmDelay: 0)
        let s = snap(.connected, pct: 100, charged: true)
        #expect(d.ingest(s, now: at(0)) == [.baseline(.connected)])
        #expect(d.ingest(s, now: at(1)).isEmpty)  // no change in percent, still connected, no event
        if case .success(let v) = s { #expect(v.summary == "Charger connected (fully charged)") }
    }
    @Test func lowBatteryDisconnectStillDetected() {
        var d = PowerTransitionDetector(confirmDelay: 0)
        _ = d.ingest(snap(.connected, pct: 3), now: at(0))
        #expect(d.ingest(snap(.disconnected, pct: 3), now: at(1)).count == 1)
    }
    @Test func apiFailureNeverTriggersTheft() {
        var d = PowerTransitionDetector(confirmDelay: 0)
        _ = d.ingest(snap(.connected), now: at(0))
        for i in 1...5 {
            let e = d.ingest(.failure(PowerReadError.unavailable), now: at(Double(i)))
            #expect(e == [.readFailed(consecutive: i)])
        }
        #expect(d.ingest(snap(.connected), now: at(9)) == [.readRecovered])
    }
    @Test func unknownStateIsNotTheft() {
        var d = PowerTransitionDetector(confirmDelay: 0)
        _ = d.ingest(snap(.connected), now: at(0))
        #expect(d.ingest(snap(.unknown), now: at(1)) == [.stateUnknown])
        #expect(d.ingest(snap(.unknown), now: at(2)).isEmpty)
        #expect(d.ingest(snap(.connected), now: at(3)).isEmpty)
    }
    @Test func reconnectAfterDisconnect() {
        var d = PowerTransitionDetector(confirmDelay: 0)
        _ = d.ingest(snap(.connected), now: at(0)); _ = d.ingest(snap(.disconnected), now: at(1))
        #expect(d.ingest(snap(.connected), now: at(2)) == [.reconnected])
    }
    @Test func wakeAfterSleepOnBatteryIsTreatedAsRealTransition() {
        var d = PowerTransitionDetector(confirmDelay: 0)
        _ = d.ingest(snap(.connected), now: at(0))
        #expect(d.ingest(snap(.disconnected), now: at(3600)).count == 1) // documented behaviour
    }
}

/// Scripted reader to drive the real PowerMonitor on the main actor.
final class ScriptedReader: PowerSourceReading, @unchecked Sendable {
    var queue: [Result<PowerSnapshot, Error>]
    init(_ q: [Result<PowerSnapshot, Error>]) { queue = q }
    func read() throws -> PowerSnapshot {
        let r = queue.count > 1 ? queue.removeFirst() : queue[0]
        return try r.get()
    }
}

@MainActor @Suite struct PowerMonitorTests {
    @Test func monitorReportsHealthAndEvents() {
        let reader = ScriptedReader([snap(.connected)])
        let m = PowerMonitor(reader: reader, notifier: nil, confirmDelay: 0, pollInterval: 3600)
        var events: [PowerEvent] = []
        m.onEvent = { e, _ in events.append(e) }
        m.start()
        #expect(events == [.baseline(.connected)]); #expect(m.health.level == .healthy)
        reader.queue = [snap(.disconnected)]; m.refresh()
        #expect(events.last.map { if case .disconnectConfirmed = $0 { true } else { false } } == true)
        m.stop()
    }
    @Test func repeatedFailuresDegradeHealthWithoutTheft() {
        let reader = ScriptedReader([snap(.connected)])
        let m = PowerMonitor(reader: reader, notifier: nil, confirmDelay: 0, pollInterval: 3600, degradedAfterFailures: 3)
        var events: [PowerEvent] = []; m.onEvent = { e, _ in events.append(e) }
        m.start()
        reader.queue = [.failure(PowerReadError.unavailable)]
        for _ in 0..<3 { m.refresh() }
        #expect(m.health.level == .degraded)
        #expect(!events.contains { if case .disconnectConfirmed = $0 { true } else { false } })
        reader.queue = [snap(.connected)]; m.refresh()
        #expect(m.health.level == .healthy)
        m.stop()
    }
}
