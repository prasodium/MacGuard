import Foundation

public struct MonitoringHealth: Equatable, Sendable {
    public enum Level: String, Sendable { case stopped, healthy, degraded }
    public var level: Level = .stopped
    public var detail: String = "Monitoring not started"
    public var lastSuccessfulRead: Date?
    public var lastSnapshot: PowerSnapshot?
    public init() {}
}

/// Wraps the detector with event-driven notifications plus a slow reconciliation poll.
/// Main-actor isolated: the IOKit run-loop source and timers live on the main run loop.
@MainActor
public final class PowerMonitor {
    public var onEvent: ((PowerEvent, PowerSnapshot?) -> Void)?
    public var onHealth: ((MonitoringHealth) -> Void)?
    public private(set) var health = MonitoringHealth()
    public private(set) var detector: PowerTransitionDetector

    private let reader: PowerSourceReading
    private let notifier: IOKitPowerNotifier?
    private let pollInterval: TimeInterval
    private let degradedAfterFailures: Int
    private var timer: Timer?
    private var confirmTimer: Timer?
    private let now: @Sendable () -> Date

    public init(reader: PowerSourceReading = IOKitPowerReader(), notifier: IOKitPowerNotifier? = IOKitPowerNotifier(),
                confirmDelay: TimeInterval = 1, pollInterval: TimeInterval = 15, degradedAfterFailures: Int = 3,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader; self.notifier = notifier; self.pollInterval = pollInterval
        self.degradedAfterFailures = degradedAfterFailures; self.now = now
        self.detector = PowerTransitionDetector(confirmDelay: confirmDelay)
    }

    public func setConfirmDelay(_ d: TimeInterval) { detector.confirmDelay = d }

    public func start() {
        stop()
        detector.reset()
        notifier?.start { [weak self] in Task { @MainActor in self?.refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = pollInterval / 4
        refresh()
    }

    public func stop() {
        notifier?.stop(); timer?.invalidate(); timer = nil
        confirmTimer?.invalidate(); confirmTimer = nil
        health.level = .stopped; health.detail = "Monitoring not started"
        onHealth?(health)
    }

    /// Re-read power state (also called after wake from sleep).
    public func refresh() {
        let result = Result { try reader.read() }
        process(result)
    }

    func process(_ result: Result<PowerSnapshot, Error>) {
        let t = now()
        let events = detector.ingest(result, now: t)
        var snapshot: PowerSnapshot?
        if case .success(let s) = result {
            snapshot = s
            health.lastSuccessfulRead = t; health.lastSnapshot = s
        }
        updateHealth(result)
        for e in events { onEvent?(e, snapshot) }
        scheduleConfirmation()
    }

    private func updateHealth(_ result: Result<PowerSnapshot, Error>) {
        var h = health
        switch result {
        case .failure:
            if detector.failureCount >= degradedAfterFailures {
                h.level = .degraded; h.detail = "Cannot read power status (\(detector.failureCount) consecutive failures)"
            }
        case .success(let s):
            if s.external == .unknown { h.level = .degraded; h.detail = "Power source state is unknown" }
            else { h.level = .healthy; h.detail = s.summary }
        }
        if h != health { health = h; onHealth?(h) }
    }

    /// While a disconnect is pending, re-read exactly when the confirmation delay elapses.
    private func scheduleConfirmation() {
        confirmTimer?.invalidate(); confirmTimer = nil
        guard let since = detector.pendingSince else { return }
        let remaining = max(0.05, detector.confirmDelay - now().timeIntervalSince(since)) + 0.02
        confirmTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
}
