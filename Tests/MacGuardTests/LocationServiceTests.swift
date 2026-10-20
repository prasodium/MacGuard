import Testing
import Foundation
@testable import MacGuardCore

@MainActor final class MockLocationProvider: LocationProviding, @unchecked Sendable {
    var authorization: LocationAuthorization = .authorized
    var fix: RawFix?
    var cached: RawFix?
    var delay: TimeInterval = 0
    var requested = false
    func requestAuthorization() { requested = true }
    func cachedFix() -> RawFix? { cached }
    func currentFix(desiredAccuracy: Double) async -> RawFix? {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return Task.isCancelled ? nil : fix
    }
}

@MainActor @Suite struct LocationServiceTests {
    let now = Date()
    func service(_ p: MockLocationProvider, store: SecurityEventStore? = nil) -> LocationService {
        let n = now; return LocationService(provider: p, store: store, now: { n })
    }
    @Test func freshFix() async {
        let p = MockLocationProvider(); p.fix = RawFix(latitude: 12.9, longitude: 77.6, accuracy: 8, timestamp: now)
        let a = await service(p).acquire(enabled: true, accuracy: .tenMeters, timeout: 2, allowLastKnown: false)
        #expect(a.outcome == .acquired); #expect(a.record?.freshness == .fresh); #expect(a.record?.horizontalAccuracy == 8)
        #expect(a.record?.acquiredAt == now)
    }
    @Test func oldFixIsClassifiedCached() async {
        let p = MockLocationProvider(); p.fix = RawFix(latitude: 1, longitude: 2, accuracy: 50, timestamp: now.addingTimeInterval(-600))
        let a = await service(p).acquire(enabled: true, accuracy: .best, timeout: 2, allowLastKnown: false)
        #expect(a.record?.freshness == .cached)
    }
    @Test func timeoutFallsBackToSystemCache() async {
        let p = MockLocationProvider(); p.delay = 5; p.cached = RawFix(latitude: 3, longitude: 4, accuracy: 100, timestamp: now.addingTimeInterval(-60))
        let start = Date()
        let a = await service(p).acquire(enabled: true, accuracy: .best, timeout: 0.3, allowLastKnown: false)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(a.outcome == .timedOut); #expect(a.record?.freshness == .cached)
    }
    @Test func timeoutWithNothingYieldsNoLocation() async {
        let p = MockLocationProvider(); p.delay = 5
        let a = await service(p).acquire(enabled: true, accuracy: .best, timeout: 0.2, allowLastKnown: true)
        #expect(a.outcome == .timedOut); #expect(a.record == nil) // never fabricated
    }
    @Test func permissionDeniedNeverReturnsFix() async {
        let p = MockLocationProvider(); p.authorization = .denied; p.fix = RawFix(latitude: 1, longitude: 2, accuracy: 5, timestamp: now)
        let a = await service(p).acquire(enabled: true, accuracy: .best, timeout: 1, allowLastKnown: false)
        #expect(a.outcome == .permissionDenied); #expect(a.record == nil); #expect(a.authorization == .denied)
    }
    @Test func disabledInSettings() async {
        let p = MockLocationProvider(); p.fix = RawFix(latitude: 1, longitude: 2, accuracy: 5, timestamp: now)
        let a = await service(p).acquire(enabled: false, accuracy: .best, timeout: 1, allowLastKnown: true)
        #expect(a.outcome == .disabledInSettings); #expect(a.record == nil)
    }
    @Test func invalidCoordinatesRejected() async {
        let p = MockLocationProvider(); p.fix = RawFix(latitude: 200, longitude: 0, accuracy: 5, timestamp: now)
        let a = await service(p).acquire(enabled: true, accuracy: .best, timeout: 1, allowLastKnown: false)
        #expect(a.outcome == .invalidCoordinates); #expect(a.record == nil)
        #expect(LocationRecord(latitude: .nan, longitude: 0, horizontalAccuracy: 1, acquiredAt: now, freshness: .fresh) == nil)
        #expect(LocationRecord(latitude: 0, longitude: 181, horizontalAccuracy: 1, acquiredAt: now, freshness: .fresh) == nil)
        #expect(LocationRecord(latitude: 0, longitude: 0, horizontalAccuracy: -5, acquiredAt: now, freshness: .fresh) == nil)
    }
    @Test func lastKnownIsLabelledAndOnlyWhenAllowed() async throws {
        let store = try SecurityEventStore(path: nil)
        let old = LocationRecord(latitude: 5, longitude: 6, horizontalAccuracy: 20, acquiredAt: now.addingTimeInterval(-86400), freshness: .fresh)!
        try store.saveLocation(old)
        let p = MockLocationProvider(); p.delay = 5
        var a = await service(p, store: store).acquire(enabled: true, accuracy: .best, timeout: 0.2, allowLastKnown: true)
        #expect(a.record?.freshness == .lastKnown); #expect(abs(a.record!.acquiredAt.timeIntervalSince(old.acquiredAt)) < 1)
        a = await service(p, store: store).acquire(enabled: true, accuracy: .best, timeout: 0.2, allowLastKnown: false)
        #expect(a.record == nil)
    }
    @Test func cancellationStopsWaiting() async {
        let p = MockLocationProvider(); p.delay = 10
        let svc = service(p)
        let task = Task { @MainActor in await svc.acquire(enabled: true, accuracy: .best, timeout: 30, allowLastKnown: false) }
        try? await Task.sleep(nanoseconds: 100_000_000); task.cancel()
        let start = Date(); let a = await task.value
        #expect(Date().timeIntervalSince(start) < 3); #expect(a.record == nil)
    }
    @Test func mapURLOnlyForValidCoordinates() {
        let r = LocationRecord(latitude: 12.97, longitude: 77.59, horizontalAccuracy: 5, acquiredAt: now, freshness: .fresh)!
        #expect(r.mapURL?.absoluteString.contains("ll=12.970000,77.590000") == true)
        #expect(r.mapURL?.scheme == "https")
    }
}
