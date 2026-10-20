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
    @Test func initialOnlyModeSendsSingleEmailAfterLocation() async throws {
        let n = MockNotifier()
        let c = TheftResponseCoordinator(alarm: MockAlarm(), locker: MockLock(), location: MockLoc(), notifier: n, store: nil, device: dev)
        var s = settings; s.followUpMode = .initialOnly
        await c.respond(to: Incident(), settings: s, hooks: hooks(Sink()))
        #expect(n.initial == 1 && n.locations == 0)
    }
}
