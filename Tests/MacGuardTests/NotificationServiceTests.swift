import Testing
import Foundation
@testable import MacGuardCore

final class MockMailer: MailSending, @unchecked Sendable {
    var script: [Result<String, APIError>] = []
    var sent: [OutgoingMail] = []
    var configured = true
    private let l = NSLock()
    var isConfigured: Bool { configured }
    func send(_ mail: OutgoingMail) async throws -> String {
        l.lock(); sent.append(mail)
        let r = script.isEmpty ? Result<String, APIError>.success("id-\(sent.count)") : script.removeFirst()
        l.unlock()
        return try r.get()
    }
    func verifyKey() async throws {}
}
let dev = DeviceInfo(name: "Test", model: "Mac14,2", osVersion: "27.0")

final class SleepLog: @unchecked Sendable { var d: [TimeInterval] = []; let l = NSLock(); func add(_ x: TimeInterval) { l.lock(); d.append(x); l.unlock() } }

@Suite struct NotificationServiceTests {
    func make(_ m: MockMailer, to: String? = "owner@gmail.com", delays: [TimeInterval] = [1, 2, 4]) throws -> (TheftNotificationService, SecurityEventStore, SleepLog) {
        let store = try SecurityEventStore(path: nil); let sl = SleepLog()
        return (TheftNotificationService(mailer: m, store: store, recipient: { to }, retryDelays: delays, sleeper: { sl.add($0) }), store, sl)
    }

    @Test func initialAlertGoesOnlyToTheVerifiedAddressWithExpectedContent() async throws {
        let m = MockMailer(); let (svc, _, _) = try make(m)
        let inc = Incident(batteryPercent: 55)
        await svc.submitInitial(inc, device: dev)
        #expect(m.sent.count == 1)
        #expect(m.sent[0].to == "owner@gmail.com")
        #expect(m.sent[0].subject == "MACGUARD ALERT: Unauthorized Charger Disconnection")
        #expect(m.sent[0].text.contains(inc.id.uuidString.lowercased())); #expect(m.sent[0].text.contains("Battery: 55%"))
        #expect(m.sent[0].text.contains("LOCATION UNAVAILABLE"))   // missing location is disclosed, never invented
    }
    @Test func locationUpdateLabelsCachedAndHasMapLink() async throws {
        let m = MockMailer(); let (svc, _, _) = try make(m)
        var inc = Incident()
        inc.location = LocationRecord(latitude: 12.9, longitude: 77.6, horizontalAccuracy: 9, acquiredAt: Date(), freshness: .cached)
        inc.locationOutcome = .timedOut
        await svc.submitLocation(inc, sequence: 1, monitoring: "healthy", followUp: false)
        #expect(m.sent[0].text.contains("CACHED LOCATION")); #expect(m.sent[0].text.contains("NOT live"))
        #expect(m.sent[0].html.contains("https://maps.apple.com/?ll=12.900000,77.600000"))
    }
    @Test func temporaryFailureRetriesWithExponentialBackoffThenSucceeds() async throws {
        let m = MockMailer(); m.script = [.failure(.network), .failure(.http(status: 503, code: nil))]
        let (svc, store, sl) = try make(m)
        await svc.submitInitial(Incident(), device: dev)
        #expect(m.sent.count == 3); #expect(sl.d == [1, 2])
        #expect(try store.outbox(state: "accepted").count == 1)
    }
    @Test func retryExhaustionKeepsItemPendingAndBounded() async throws {
        let m = MockMailer(); m.script = Array(repeating: .failure(.timeout), count: 50)
        let (svc, store, sl) = try make(m, delays: [1, 2])
        await svc.submitInitial(Incident(), device: dev)
        #expect(m.sent.count == 3); #expect(sl.d == [1, 2])
        let pending = try store.outbox(state: "pending")
        #expect(pending.count == 1); #expect(pending[0].attempts == 3); #expect(pending[0].lastError != nil)
    }
    @Test func rejectedKeyIsPermanentNotRetried() async throws {
        let m = MockMailer(); m.script = [.failure(.http(status: 401, code: "unauthorized"))]
        let (svc, store, sl) = try make(m)
        await svc.submitInitial(Incident(), device: dev)
        #expect(m.sent.count == 1); #expect(sl.d.isEmpty); #expect(try store.outbox(state: "failed").count == 1)
    }
    @Test func errorClassification() {
        #expect(APIError.http(status: 502, code: nil).isRetryable); #expect(APIError.http(status: 429, code: nil).isRetryable)
        #expect(APIError.network.isRetryable)
        #expect(!APIError.http(status: 400, code: "invalid_parameter").isRetryable); #expect(!APIError.http(status: 401, code: nil).isRetryable)
        #expect(!APIError.insecureScheme.isRetryable); #expect(!APIError.notConfigured.isRetryable)
    }
    @Test func duplicateEventIsNotQueuedOrSentTwice() async throws {
        let m = MockMailer(); let (svc, store, _) = try make(m)
        let inc = Incident()
        await svc.submitInitial(inc, device: dev); await svc.submitInitial(inc, device: dev)
        #expect(m.sent.count == 1); #expect(try store.outbox().count == 1)
    }
    @Test func pendingAlertsAreSentWhenConnectivityReturns() async throws {
        let m = MockMailer(); m.script = [.failure(.network)]
        let (svc, store, _) = try make(m, delays: [])
        await svc.submitInitial(Incident(), device: dev)
        #expect(try store.outbox(state: "pending").count == 1)
        try store.updateOutbox(id: try store.outbox()[0].id, state: "pending", attempts: 1, next: Date(), error: nil)
        await svc.flush()
        #expect(try store.outbox(state: "accepted").count == 1)
    }
    @Test func alertWaitsForAVerifiedAddressThenSends() async throws {
        let m = MockMailer(); let box = MailConfig()
        let store = try SecurityEventStore(path: nil)
        let svc = TheftNotificationService(mailer: m, store: store, recipient: { box.recipient }, retryDelays: [], sleeper: { _ in })
        await svc.submitInitial(Incident(), device: dev)
        #expect(m.sent.isEmpty)                                   // nothing goes anywhere unverified
        #expect(try store.outbox(state: "pending").count == 1)    // but the alert is kept
        box.recipient = "me@gmail.com"
        try store.updateOutbox(id: try store.outbox()[0].id, state: "pending", attempts: 0, next: Date(), error: nil)
        await svc.flush()
        #expect(m.sent.count == 1); #expect(m.sent[0].to == "me@gmail.com")
    }
    @Test func testEmailSuccessFailureAndNoRecipient() async throws {
        let m = MockMailer(); let (svc, _, _) = try make(m)
        if case .success = await svc.sendTest(device: dev) {} else { Issue.record("expected success") }
        #expect(m.sent[0].subject == "MACGUARD TEST: Alert email")
        m.script = [.failure(.http(status: 401, code: nil))]
        if case .failure(let e) = await svc.sendTest(device: dev) { #expect(e == .http(status: 401, code: nil)) } else { Issue.record("expected failure") }
        let (none, _, _) = try make(MockMailer(), to: nil)
        if case .failure(let e) = await none.sendTest(device: dev) { #expect(e == .noRecipient) } else { Issue.record("must not send without a verified address") }
    }
}

@Suite struct OfflineLocationQueueTests {
    @Test func onlyTheNewestQueuedLocationIsSentOnceBackOnline() async throws {
        let m = MockMailer(); let store = try SecurityEventStore(path: nil)
        let svc = TheftNotificationService(mailer: m, store: store, recipient: { nil }, retryDelays: [1], sleeper: { _ in })   // offline: no way to send
        var inc = Incident(); inc.locationOutcome = .timedOut
        for seq in [2, 3, 9, 10] { await svc.submitLocation(inc, sequence: seq, monitoring: "healthy", followUp: true) }
        #expect(m.sent.isEmpty)
        for it in try store.outbox(state: "pending") { try store.updateOutbox(id: it.id, state: "pending", attempts: it.attempts, next: Date(), error: it.lastError) }   // the retry time arrives
        let back = TheftNotificationService(mailer: m, store: store, recipient: { "owner@gmail.com" }, retryDelays: [1], sleeper: { _ in })
        await back.flush()                                                     // connection returned
        #expect(m.sent.count == 1)
        #expect(try store.outbox(state: "superseded").count == 3)
        #expect(try store.outbox(state: "accepted").contains { $0.id.hasSuffix(":location:10") })   // 10 beats 9 numerically
    }
}

@Suite struct FoundMacTests {
    @Test func foundCancelsEverythingNotYetSentForThatIncidentOnly() async throws {
        let m = MockMailer(); let store = try SecurityEventStore(path: nil)
        let off = TheftNotificationService(mailer: m, store: store, recipient: { nil }, retryDelays: [1], sleeper: { _ in })   // offline
        let a = Incident(), b = Incident()
        await off.submitInitial(a, device: dev)
        await off.submitLocation(a, sequence: 2, monitoring: "healthy", followUp: true)
        await off.submitInitial(b, device: dev)
        await off.cancelPending(incidentID: a.id)                    // owner pressed "I found my Mac" for incident a
        #expect(try store.outbox(state: "cancelled").count == 2)
        #expect(try store.outbox(state: "pending").count == 1)       // incident b is untouched
        for it in try store.outbox(state: "pending") { try store.updateOutbox(id: it.id, state: "pending", attempts: 0, next: Date(), error: nil) }
        let on = TheftNotificationService(mailer: m, store: store, recipient: { "owner@gmail.com" }, retryDelays: [1], sleeper: { _ in })
        await on.flush()                                             // internet is back
        #expect(m.sent.count == 1)                                   // only incident b's alert; nothing for the found Mac
        #expect(m.sent[0].text.contains(b.id.uuidString.lowercased()))
    }

    @Test func foundStatusEmailExplainsNoMoreEmailsWillCome() {
        let r = EmailTemplates.status(StatusPayload(incidentId: "x", statusCode: "mac_found", monitoringState: "healthy", timestamp: Date()))
        #expect(r.text.contains("found")); #expect(r.text.contains("No more location emails"))
    }
}

