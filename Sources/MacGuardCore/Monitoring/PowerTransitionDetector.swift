import Foundation

public enum PowerEvent: Equatable, Sendable {
    case baseline(ExternalPower)
    case disconnectPending(since: Date)
    case disconnectCancelled
    case disconnectConfirmed(at: Date)
    case reconnected
    case readFailed(consecutive: Int)
    case readRecovered
    case stateUnknown
}

/// Pure, deterministic logic: turns a stream of power readings into transition events.
/// A read failure or an unknown state is never treated as a disconnection.
public struct PowerTransitionDetector: Sendable {
    public var confirmDelay: TimeInterval
    public private(set) var last: ExternalPower?
    public private(set) var pendingSince: Date?
    public private(set) var failureCount = 0
    private var reportedUnknown = false

    public init(confirmDelay: TimeInterval = 1) { self.confirmDelay = confirmDelay }

    public mutating func reset() {
        last = nil; pendingSince = nil; failureCount = 0; reportedUnknown = false
    }

    public mutating func ingest(_ result: Result<PowerSnapshot, Error>, now: Date) -> [PowerEvent] {
        var out: [PowerEvent] = []
        switch result {
        case .failure:
            failureCount += 1
            out.append(.readFailed(consecutive: failureCount))
        case .success(let s):
            if failureCount > 0 { failureCount = 0; out.append(.readRecovered) }
            switch s.external {
            case .unknown:
                if !reportedUnknown { reportedUnknown = true; out.append(.stateUnknown) }
            case .connected:
                reportedUnknown = false
                if pendingSince != nil { pendingSince = nil; out.append(.disconnectCancelled) }
                if last == nil { out.append(.baseline(.connected)) }
                else if last == .disconnected { out.append(.reconnected) }
                last = .connected
            case .disconnected:
                reportedUnknown = false
                if last == nil {
                    last = .disconnected; out.append(.baseline(.disconnected))
                } else if last == .connected {
                    if let since = pendingSince {
                        if now.timeIntervalSince(since) >= confirmDelay {
                            pendingSince = nil; last = .disconnected
                            out.append(.disconnectConfirmed(at: since))
                        }
                    } else if confirmDelay <= 0 {
                        last = .disconnected; out.append(.disconnectConfirmed(at: now))
                    } else {
                        pendingSince = now; out.append(.disconnectPending(since: now))
                    }
                }
                // last == .disconnected: duplicate notification, no event.
            }
        }
        return out
    }
}
