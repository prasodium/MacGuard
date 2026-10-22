import Testing
import Foundation
@testable import MacGuardCore

@MainActor final class MockAlarm: AlarmControlling {
    var isActive = false; var startCount = 0
    func start(settings: AlarmSettings) -> Bool { startCount += 1; isActive = true; return true }
    func stop() { isActive = false }
    func preview(settings: AlarmSettings) {}
}
struct MockLock: ScreenLocking { var result: ActionStatus = .requestedUnverified; func lock() async -> ActionStatus { result } }
@MainActor final class MockLoc: LocationResolving {
    var result = LocationAcquisition(outcome: .timedOut, record: nil, authorization: .authorized); var delay: TimeInterval = 0
    func acquire(enabled: Bool, accuracy: LocationAccuracySetting, timeout: TimeInterval, allowLastKnown: Bool) async -> LocationAcquisition {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return result
    }
}
final class MockNotifier: IncidentNotifying, @unchecked Sendable {
    var initial = 0, locations = 0, statuses = 0; var order: [String] = []; var hang = false
    func submitInitial(_ incident: Incident, device: DeviceInfo) async { initial += 1; order.append("initial") }
    func submitLocation(_ incident: Incident, sequence: Int, monitoring: String, followUp: Bool) async { locations += 1; order.append("loc") }
    func submitStatus(incidentID: UUID, code: String, monitoring: String) async { statuses += 1 }
    func sendTest(device: DeviceInfo) async -> Result<String, APIError> { .success("x") }
    func flush() async {}
}

@MainActor @Suite struct TheftResponseTests {
    final class Sink { var events: [GuardEvent] = []; var logs: [SecurityEventType] = []; var incident: Incident?; var notes = 0 }
    func hooks(_ s: Sink) -> TheftResponseCoordinator.Hooks {
        .init(transition: { s.events.append($0) }, update: { s.incident = $0 }, log: { t, _, _ in s.logs.append(t) },
              monitoringState: { "healthy" }, localNotification: { _, _ in s.notes += 1 })
    }
    var settings: AppSettings { var s = AppSettings(); s.emailEnabled = true; s.locationTimeout = 1; return s }

    @Test func alarmLockLocationAndEmailAllRun() async throws {
        let alarm = MockAlarm(); let n = MockNotifier(); let loc = MockLoc()
        loc.result = LocationAcquisition(outcome: .acquired, record: LocationRecord(latitude: 1, longitude: 2, horizontalAccuracy: 5, acquiredAt: Date(), freshness: .fresh), authorization: .authorized)
        let c = TheftResponseCoordinator(alarm: alarm, locker: MockLock(), location: loc, notifier: n, store: try SecurityEventStore(path: nil), device: dev)
        let sink = Sink()
        await c.respond(to: Incident(), settings: settings, hooks: hooks(sink))
        #expect(alarm.startCount == 1 && alarm.isActive)
        #expect(sink.events.first == .alarmStarted)
        #expect(n.initial == 1 && n.locations == 1)
        #expect(sink.incident?.screenLock == .requestedUnverified); #expect(sink.incident?.alarm == .succeeded)
        #expect(sink.incident?.location?.freshness == .fresh)
        #expect(sink.logs.contains(.alarmStarted) && sink.logs.contains(.screenLockRequested) && sink.logs.contains(.locationAcquired))
    }
    @Test func duplicateIncidentRunsResponseOnce() async throws {
        let alarm = MockAlarm(); let n = MockNotifier()
        let c = TheftResponseCoordinator(alarm: alarm, locker: MockLock(), location: MockLoc(), notifier: n, store: nil, device: dev)
        let inc = Incident(); let sink = Sink()
        await c.respond(to: inc, settings: settings, hooks: hooks(sink)); await c.respond(to: inc, settings: settings, hooks: hooks(sink))
        #expect(alarm.startCount == 1); #expect(n.initial == 1)
    }
    @Test func alarmDoesNotDependOnEmailOrLocation() async throws {
        let alarm = MockAlarm()
        let c = TheftResponseCoordinator(alarm: alarm, locker: MockLock(result: .failed), location: MockLoc(), notifier: nil, store: nil, device: dev)
        let sink = Sink(); var s = settings; s.emailEnabled = false
        await c.respond(to: Incident(), settings: s, hooks: hooks(sink))
        #expect(alarm.isActive); #expect(sink.incident?.screenLock == .failed); #expect(sink.incident?.notification == .disabled)
    }
    @Test func initialAlertDoesNotWaitForSlowLocation() async throws {
        let alarm = MockAlarm(); let n = MockNotifier(); let loc = MockLoc(); loc.delay = 0.5
        let c = TheftResponseCoordinator(alarm: alarm, locker: MockLock(), location: loc, notifier: n, store: nil, device: dev)
        var s = settings; s.followUpMode = .oneFollowUp
        await c.respond(to: Incident(), settings: s, hooks: hooks(Sink()))
        #expect(n.order == ["initial", "loc"]) // initial first, location update after
    }
    @Test func secondIncidentAfterReconnectSoundsTheAlarmAgain() async throws {
        let alarm = MockAlarm(); let n = MockNotifier()
        let c = TheftResponseCoordinator(alarm: alarm, locker: MockLock(), location: MockLoc(), notifier: n, store: nil, device: dev)
        await c.respond(to: Incident(), settings: settings, hooks: hooks(Sink()))
        #expect(alarm.startCount == 1)
        alarm.stop()                                   // charger reconnected -> alarm silenced
        await c.respond(to: Incident(), settings: settings, hooks: hooks(Sink()))
        #expect(alarm.startCount == 2 && alarm.isActive)
        #expect(n.initial == 2)                        // each incident gets its own alert
    }
    @Test func initialOnlyModeSendsSingleEmailAfterLocation() async throws {
        let n = MockNotifier()
        let c = TheftResponseCoordinator(alarm: MockAlarm(), locker: MockLock(), location: MockLoc(), notifier: n, store: nil, device: dev)
        var s = settings; s.followUpMode = .initialOnly
        await c.respond(to: Incident(), settings: s, hooks: hooks(Sink()))
        #expect(n.initial == 1 && n.locations == 0)
    }
}

final class WaitLog: @unchecked Sendable {
    private let l = NSLock(); private var w: [TimeInterval] = []
    func add(_ x: TimeInterval) { l.lock(); w.append(x); l.unlock() }
    var all: [TimeInterval] { l.lock(); defer { l.unlock() }; return w }
}

@MainActor @Suite struct RepeatWhileUnpluggedTests {
    var periodic: AppSettings {
        var s = AppSettings(); s.emailEnabled = true; s.locationTimeout = 1
        s.followUpMode = .periodic; s.followUpInterval = 600; s.followUpMaxDuration = 3000   // every 10 min, for 50 min
        return s
    }
    func hooks() -> TheftResponseCoordinator.Hooks {
        .init(transition: { _ in }, update: { _ in }, log: { _, _, _ in }, monitoringState: { "healthy" }, localNotification: { _, _ in })
    }
    func waitUntil(_ cond: @MainActor () -> Bool) async { for _ in 0..<400 where !cond() { try? await Task.sleep(nanoseconds: 5_000_000) } }

    @Test func sendsAnEmailEveryIntervalCountedFromTheDisconnect() async throws {
        let n = MockNotifier(); let log = WaitLog()
        let c = TheftResponseCoordinator(alarm: MockAlarm(), locker: MockLock(), location: MockLoc(), notifier: n, store: nil, device: dev,
                                         sleep: { log.add($0); try? await Task.sleep(nanoseconds: 2_000_000) })
        await c.respond(to: Incident(), settings: periodic, hooks: hooks())
        await waitUntil { n.locations >= 6 }
        #expect(n.initial == 1)
        #expect(n.locations == 6)                                  // location update, then 5 repeats (10 min x 5 = 50 min)
        let waits = log.all
        #expect(waits.count >= 5)
        for (i, w) in waits.prefix(5).enumerated() { #expect(abs(w - Double(i + 1) * 600) < 5) }   // 10, 20, 30, 40, 50 min after the unplug
    }

    @Test func reconnectingTheChargerStopsAndResetsTheRepeat() async throws {
        let n = MockNotifier()
        let c = TheftResponseCoordinator(alarm: MockAlarm(), locker: MockLock(), location: MockLoc(), notifier: n, store: nil, device: dev,
                                         sleep: { _ in while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) } })   // "waiting" until cancelled
        await c.respond(to: Incident(), settings: periodic, hooks: hooks())
        #expect(n.locations == 1)
        c.cancelFollowUps()                                         // charger plugged back in
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(n.locations == 1)                                   // nothing more is sent
        await c.respond(to: Incident(), settings: periodic, hooks: hooks())   // unplugged again: new incident, new timer
        #expect(n.initial == 2 && n.locations == 2)
        c.cancelFollowUps()
    }

    @Test func otherModesDoNotRepeat() async throws {
        let n = MockNotifier(); var s = periodic; s.followUpMode = .oneFollowUp
        let c = TheftResponseCoordinator(alarm: MockAlarm(), locker: MockLock(), location: MockLoc(), notifier: n, store: nil, device: dev,
                                         sleep: { _ in try? await Task.sleep(nanoseconds: 1_000_000) })
        await c.respond(to: Incident(), settings: s, hooks: hooks())
        try? await Task.sleep(nanoseconds: 60_000_000)
        #expect(n.initial == 1 && n.locations == 1)
    }

    @Test func theEarlierWaitBetweenEmailsSettingBecomesRepeatEvery() throws {
        let json = #"{"emailEnabled":true,"emailMinInterval":600}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(s.followUpMode == .periodic); #expect(s.followUpInterval == 600)
        let plain = try JSONDecoder().decode(AppSettings.self, from: #"{"emailEnabled":true}"#.data(using: .utf8)!)
        #expect(plain.followUpMode == .oneFollowUp)
    }
}
