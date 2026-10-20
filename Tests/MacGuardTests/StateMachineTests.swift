import Testing
import Foundation
@testable import MacGuardCore

func check(_ m: inout GuardStateMachine, _ e: GuardEvent, _ expected: Bool = true) {
    let r = m.apply(e)
    #expect(r == expected)
}

@Suite struct StateMachineTests {
    func armed() -> GuardStateMachine {
        var m = GuardStateMachine()
        check(&m, .requestArm); check(&m, .armConfirmed)
        return m
    }
    @Test func validArmingSequence() {
        var m = GuardStateMachine()
        #expect(m.phase == .disarmed)
        m.apply(.requestArm); #expect(m.phase == .preparingToArm)
        m.apply(.armConfirmed); #expect(m.phase == .armed)
    }
    @Test func invalidArmingIsRejected() {
        var m = GuardStateMachine()
        check(&m, .armConfirmed, false); #expect(m.phase == .disarmed)
        check(&m, .theftConfirmed(incident: UUID()), false); #expect(m.phase == .disarmed) // disconnect while disarmed
        m.apply(.requestArm); check(&m, .requestArm, false)
    }
    @Test func armFailureReturnsToDisarmed() {
        var m = GuardStateMachine(); m.apply(.requestArm); m.apply(.armFailed)
        #expect(m.phase == .disarmed)
    }
    @Test func fullTheftFlow() {
        var m = armed(); let id = UUID()
        m.apply(.powerDisconnectPending); #expect(m.phase == .powerTransitionPending)
        m.apply(.theftConfirmed(incident: id)); #expect(m.phase == .theftDetected); #expect(m.incidentID == id)
        m.apply(.alarmStarted); #expect(m.phase == .alarmActive)
        m.apply(.locationStarted); #expect(m.phase == .locationPending)
        m.apply(.locationFinished); #expect(m.phase == .notificationPending)
        m.apply(.notificationSent); #expect(m.phase == .notificationSent)
    }
    @Test func duplicateIncidentSuppressed() {
        var m = armed(); let a = UUID()
        check(&m, .theftConfirmed(incident: a))
        check(&m, .theftConfirmed(incident: UUID()), false); #expect(m.incidentID == a)
    }
    @Test func lateCompletionsNeverRegress() {
        var m = armed(); m.apply(.theftConfirmed(incident: UUID()))
        m.apply(.notificationSent); #expect(m.phase == .notificationSent)
        m.apply(.alarmStarted); m.apply(.locationStarted); m.apply(.locationFinished)
        #expect(m.phase == .notificationSent)
    }
    @Test func cancelledTransitionReturnsToArmed() {
        var m = armed(); m.apply(.powerDisconnectPending); m.apply(.powerDisconnectCancelled)
        #expect(m.phase == .armed)
    }
    @Test func reconnectionDoesNotDisarm() {
        var m = armed(); m.apply(.theftConfirmed(incident: UUID())); m.apply(.alarmStarted)
        m.apply(.chargerReconnected)
        #expect(m.phase == .alarmActive); #expect(m.chargerReconnected); #expect(m.isProtecting)
        m.apply(.notificationSent); #expect(m.phase == .recoveryPending)
    }
    @Test func reconnectAfterNotificationGoesToRecoveryPending() {
        var m = armed(); m.apply(.theftConfirmed(incident: UUID())); m.apply(.notificationSent)
        m.apply(.chargerReconnected); #expect(m.phase == .recoveryPending)
    }
    @Test func unauthorizedDisarmRejectedDuringIncident() {
        var m = armed(); m.apply(.theftConfirmed(incident: UUID()))
        check(&m, .disarm(authorized: false), false); #expect(m.phase == .theftDetected)
        check(&m, .disarm(authorized: true)); #expect(m.phase == .disarmed); #expect(m.incidentID == nil)
    }
    @Test func disarmingBeforeTransitionPreventsTheft() {
        var m = armed(); m.apply(.disarm(authorized: true))
        check(&m, .theftConfirmed(incident: UUID()), false); #expect(m.phase == .disarmed)
    }
    @Test func degradationAndRecovery() {
        var m = armed(); m.apply(.monitoringFailed); #expect(m.phase == .monitoringDegraded)
        m.apply(.monitoringRecovered); #expect(m.phase == .armed)
        check(&m, .monitoringRecovered, false)
    }
    @Test func degradedStillRespondsToTheft() {
        var m = armed(); m.apply(.monitoringFailed)
        check(&m, .theftConfirmed(incident: UUID()))
    }
}
