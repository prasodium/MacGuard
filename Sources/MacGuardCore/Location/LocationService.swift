import Foundation
import CoreLocation

/// Raw platform location source. Implementations must never fabricate positions.
public protocol LocationProviding: AnyObject, Sendable {
    @MainActor var authorization: LocationAuthorization { get }
    @MainActor func requestAuthorization()
    /// Returns the best position it can produce until cancelled; the service enforces the timeout.
    @MainActor func currentFix(desiredAccuracy: Double) async -> RawFix?
    @MainActor func cachedFix() -> RawFix?
}

public struct RawFix: Equatable, Sendable {
    public var latitude: Double, longitude: Double, accuracy: Double, timestamp: Date
    public init(latitude: Double, longitude: Double, accuracy: Double, timestamp: Date) {
        self.latitude = latitude; self.longitude = longitude; self.accuracy = accuracy; self.timestamp = timestamp
    }
}

public protocol LocationResolving: Sendable {
    @MainActor func acquire(enabled: Bool, accuracy: LocationAccuracySetting, timeout: TimeInterval,
                            allowLastKnown: Bool) async -> LocationAcquisition
}

/// Applies permission checks, timeout, freshness classification and last-known fallback.
public final class LocationService: LocationResolving, @unchecked Sendable {
    private let provider: LocationProviding
    private let store: SecurityEventStore?
    private let now: @Sendable () -> Date
    /// A fix older than this at request time is classified "cached".
    public static let freshnessWindow: TimeInterval = 30

    public init(provider: LocationProviding, store: SecurityEventStore?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider; self.store = store; self.now = now
    }

    @MainActor public func acquire(enabled: Bool, accuracy: LocationAccuracySetting, timeout: TimeInterval,
                                   allowLastKnown: Bool) async -> LocationAcquisition {
        let auth = provider.authorization
        guard enabled else { return LocationAcquisition(outcome: .disabledInSettings, record: nil, authorization: auth) }
        guard auth == .authorized else {
            return LocationAcquisition(outcome: .permissionDenied, record: lastKnown(allowLastKnown), authorization: auth)
        }
        let started = now()
        let cached = provider.cachedFix()
        let fix = await Self.withTimeout(timeout) { await self.provider.currentFix(desiredAccuracy: accuracy.meters) }
        if Task.isCancelled { return LocationAcquisition(outcome: .cancelled, record: nil, authorization: auth) }

        if let fix {
            guard let rec = Self.record(fix, requestStart: started) else {
                return LocationAcquisition(outcome: .invalidCoordinates, record: lastKnown(allowLastKnown), authorization: auth)
            }
            persist(rec)
            return LocationAcquisition(outcome: .acquired, record: rec, authorization: auth)
        }
        // No fix inside the timeout: accept a valid cached system fix, else the stored last-known location.
        if let c = cached, let rec = Self.record(c, requestStart: started, forceCached: true) {
            return LocationAcquisition(outcome: .timedOut, record: rec, authorization: auth)
        }
        return LocationAcquisition(outcome: .timedOut, record: lastKnown(allowLastKnown), authorization: auth)
    }

    static func record(_ f: RawFix, requestStart: Date, forceCached: Bool = false) -> LocationRecord? {
        let fresh = !forceCached && requestStart.timeIntervalSince(f.timestamp) <= freshnessWindow
        return LocationRecord(latitude: f.latitude, longitude: f.longitude, horizontalAccuracy: f.accuracy >= 0 ? f.accuracy : nil,
                              acquiredAt: f.timestamp, freshness: fresh ? .fresh : .cached)
    }

    private func persist(_ r: LocationRecord) { try? store?.saveLocation(r) }

    private func lastKnown(_ allowed: Bool) -> LocationRecord? {
        guard allowed, var r = try? store?.lastLocation() else { return nil }
        r.freshness = .lastKnown
        return r
    }

    @MainActor static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ op: @escaping @MainActor @Sendable () async -> T?) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { @MainActor in await op() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Core Location provider

@MainActor
public final class CoreLocationProvider: NSObject, LocationProviding, CLLocationManagerDelegate, ObservableObject, @unchecked Sendable {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<RawFix?, Never>?
    private var target: Double = 10
    private var best: CLLocation?
    @Published public private(set) var authorization: LocationAuthorization = .notDetermined

    public override init() {
        super.init()
        manager.delegate = self
        refreshAuth()
    }

    private func refreshAuth() {
        guard CLLocationManager.locationServicesEnabled() else { authorization = .servicesDisabled; return }
        switch manager.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .restricted: authorization = .restricted
        case .denied: authorization = .denied
        default: authorization = .authorized
        }
    }

    public func requestAuthorization() { manager.requestWhenInUseAuthorization() }

    public func cachedFix() -> RawFix? {
        guard let l = manager.location, l.horizontalAccuracy >= 0 else { return nil }
        return RawFix(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude, accuracy: l.horizontalAccuracy, timestamp: l.timestamp)
    }

    public func currentFix(desiredAccuracy: Double) async -> RawFix? {
        target = desiredAccuracy; best = nil
        manager.desiredAccuracy = desiredAccuracy <= 10 ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<RawFix?, Never>) in
                continuation = c
                manager.startUpdatingLocation()
            }
        } onCancel: { Task { @MainActor in self.finish(useBest: true) } }
    }

    private func finish(useBest: Bool) {
        manager.stopUpdatingLocation()
        guard let c = continuation else { return }
        continuation = nil
        if useBest, let l = best, l.horizontalAccuracy >= 0 {
            c.resume(returning: RawFix(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                                       accuracy: l.horizontalAccuracy, timestamp: l.timestamp))
        } else { c.resume(returning: nil) }
    }

    nonisolated public func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            for l in locations where l.horizontalAccuracy >= 0 {
                if self.best == nil || l.horizontalAccuracy < self.best!.horizontalAccuracy { self.best = l }
            }
            if let b = self.best, b.horizontalAccuracy <= self.target, abs(b.timestamp.timeIntervalSinceNow) < 30 { self.finish(useBest: true) }
        }
    }
    nonisolated public func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        // kCLErrorLocationUnknown is transient; keep waiting until the service timeout.
        if (error as? CLError)?.code == .locationUnknown { return }
        Task { @MainActor in self.finish(useBest: true) }
    }
    nonisolated public func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Task { @MainActor in self.refreshAuth() }
    }
}
