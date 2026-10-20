import Foundation

public enum GuardPhase: String, Codable, Sendable, CaseIterable {
    case disarmed, preparingToArm, armed, powerTransitionPending
    case theftDetected, alarmActive, locationPending, notificationPending, notificationSent
    case recoveryPending, monitoringDegraded

    /// Ordering of the forward-only theft response flow; nil for non-theft phases.
    var theftRank: Int? {
        switch self {
        case .theftDetected: return 1
        case .alarmActive: return 2
        case .locationPending: return 3
        case .notificationPending: return 4
        case .notificationSent: return 5
        case .recoveryPending: return 6
        default: return nil
        }
    }
    public var isTheftFlow: Bool { theftRank != nil }
}

public enum GuardEvent: Equatable, Sendable {
    case requestArm
    case armConfirmed
    case armFailed
    case disarm(authorized: Bool)
    case powerDisconnectPending
    case powerDisconnectCancelled
    case theftConfirmed(incident: UUID)
    case alarmStarted
    case locationStarted
    case locationFinished
    case notificationSent
    case chargerReconnected
    case monitoringFailed
    case monitoringRecovered
}

/// Explicit, testable security state machine. Late async completions never move the
/// theft flow backwards; invalid events are rejected and leave state unchanged.
public struct GuardStateMachine: Equatable, Sendable {
    public private(set) var phase: GuardPhase = .disarmed
    public private(set) var incidentID: UUID?
    public private(set) var chargerReconnected = false
    private var resumePhase: GuardPhase = .armed

    public init(phase: GuardPhase = .disarmed) { self.phase = phase }

    @discardableResult
    public mutating func apply(_ event: GuardEvent) -> Bool {
        switch (phase, event) {
        case (.disarmed, .requestArm): phase = .preparingToArm
        case (.preparingToArm, .armConfirmed): phase = .armed
        case (.preparingToArm, .armFailed): phase = .disarmed
        case (.preparingToArm, .disarm): phase = .disarmed

        case (.armed, .powerDisconnectPending): phase = .powerTransitionPending
        case (.powerTransitionPending, .powerDisconnectCancelled): phase = .armed
        case (.armed, .theftConfirmed(let id)), (.powerTransitionPending, .theftConfirmed(let id)):
            phase = .theftDetected; incidentID = id; chargerReconnected = false
        case (.armed, .disarm(true)), (.powerTransitionPending, .disarm(true)), (.monitoringDegraded, .disarm(true)):
            phase = .disarmed
        case (.armed, .monitoringFailed), (.powerTransitionPending, .monitoringFailed):
            resumePhase = .armed; phase = .monitoringDegraded
        case (.monitoringDegraded, .monitoringRecovered): phase = resumePhase
        case (.monitoringDegraded, .theftConfirmed(let id)):
            phase = .theftDetected; incidentID = id; chargerReconnected = false

        case (let p, .alarmStarted) where p.isTheftFlow: advance(.alarmActive)
        case (let p, .locationStarted) where p.isTheftFlow: advance(.locationPending)
        case (let p, .locationFinished) where p.isTheftFlow: advance(.notificationPending)
        case (let p, .notificationSent) where p.isTheftFlow:
            advance(.notificationSent)
            if chargerReconnected { phase = .recoveryPending }
        case (let p, .chargerReconnected) where p.isTheftFlow:
            chargerReconnected = true
            if let r = p.theftRank, r >= GuardPhase.notificationSent.theftRank! { phase = .recoveryPending }

        case (let p, .disarm(true)) where p.isTheftFlow:
            phase = .disarmed; incidentID = nil; chargerReconnected = false
        default:
            return false
        }
        return true
    }

    private mutating func advance(_ target: GuardPhase) {
        if let cur = phase.theftRank, let t = target.theftRank, t > cur { phase = target }
    }

    public var isProtecting: Bool {
        [.armed, .powerTransitionPending, .monitoringDegraded].contains(phase) || phase.isTheftFlow
    }
}
