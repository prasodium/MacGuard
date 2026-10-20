import Testing
import Foundation
@testable import MacGuardCore

final class MockAPI: AlertAPI, @unchecked Sendable {
    var script: [Result<APIResponse, APIError>] = []
    var calls: [(path: String, body: Data)] = []
    var isEnrolled = true
    private let l = NSLock()
    func post(path: String, body: Data) async throws -> APIResponse {
        l.lock(); calls.append((path, body))
        let r = script.isEmpty ? .success(APIResponse(status: 200, body: Data(#"{"status":"accepted","providerId":"p1"}"#.utf8))) : script.removeFirst()
        l.unlock()
        return try r.get()
    }
    func enroll(token: String, deviceName: String) async throws {}
}
let ok = Result<APIResponse, APIError>.success(APIResponse(status: 200, body: Data(#"{"status":"accepted"}"#.utf8)))
let dev = DeviceInfo(name: "Test", model: "Mac14,2", osVersion: "27.0")

final class Recorder: @unchecked Sendable {
    var statuses: [NotificationStatus] = []; let l = NSLock()
    func add(_ s: NotificationStatus) { l.lock(); statuses.append(s); l.unlock() }
}

@Suite struct NotificationServiceTests {
    func make(_ api: MockAPI, delays: [TimeInterval] = [1, 2, 4]) throws -> (TheftNotificationService, SecurityEventStore, Recorder, SleepLog) {
        let store = try SecurityEventStore(path: nil); let rec = Recorder(); let sl = SleepLog()
        let svc = TheftNotificationService(api: api, store: store, retryDelays: delays, sleeper: { sl.add($0) })
        return (svc, store, rec, sl)
    }
    final class SleepLog: @unchecked Sendable { var d: [TimeInterval] = []; let l = NSLock(); func add(_ x: TimeInterval) { l.lock(); d.append(x); l.unlock() } }

    @Test func validAlertPayloadWithoutLocation() async throws {
        let api = MockAPI(); let (svc, _, _, _) = try make(api)
        let inc = Incident(batteryPercent: 55)
        await svc.submitInitial(inc, device: dev)
        #expect(api.calls.count == 1); #expect(api.calls[0].path == "/v1/incidents")
        let o = try #require(try JSONSerialization.jsonObject(with: api.calls[0].body) as? [String: Any])
        #expect(o["incidentId"] as? String == inc.id.uuidString.lowercased())
        #expect(o["location"] == nil || o["location"] is NSNull); #expect(o["batteryPercent"] as? Int == 55)
        #expect(o["eventType"] as? String == "charger_disconnected")
    }
    @Test func freshAndCachedLocationPayloads() async throws {
        let api = MockAPI(); let (svc, _, _, _) = try make(api)
        var inc = Incident()
        inc.location = LocationRecord(latitude: 1, longitude: 2, horizontalAccuracy: 9, acquiredAt: Date(), freshness: .cached)
        inc.locationOutcome = .timedOut
        await svc.submitLocation(inc, sequence: 1, monitoring: "healthy", followUp: false)
        let o = try #require(try JSONSerialization.jsonObject(with: api.calls[0].body) as? [String: Any])
        #expect((o["location"] as? [String: Any])?["freshness"] as? String == "cached")
        #expect(api.calls[0].path == "/v1/incidents/\(inc.id.uuidString.lowercased())/location")
    }
    @Test func temporaryFailureRetriesWithExponentialBackoffThenSucceeds() async throws {
        let api = MockAPI(); api.script = [.failure(.network), .failure(.http(status: 503, code: nil)), ok]
        let (svc, store, _, sl) = try make(api)
        let inc = Incident()
        await svc.submitInitial(inc, device: dev)
        #expect(api.calls.count == 3); #expect(sl.d == [1, 2])
        #expect(try store.outbox(state: "accepted").count == 1)
    }
    @Test func retryExhaustionKeepsItemPendingAndBounded() async throws {
        let api = MockAPI(); api.script = Array(repeating: .failure(.timeout), count: 50)
        let (svc, store, _, sl) = try make(api, delays: [1, 2])
        await svc.submitInitial(Incident(), device: dev)
        #expect(api.calls.count == 3); #expect(sl.d == [1, 2])       // bounded
        let pending = try store.outbox(state: "pending")
        #expect(pending.count == 1); #expect(pending[0].attempts == 3); #expect(pending[0].lastError != nil)
    }
    @Test func authenticationFailureIsPermanent() async throws {
        let api = MockAPI(); api.script = [.failure(.http(status: 401, code: "unauthorized"))]
        let (svc, store, _, sl) = try make(api)
        await svc.submitInitial(Incident(), device: dev)
        #expect(api.calls.count == 1); #expect(sl.d.isEmpty); #expect(try store.outbox(state: "failed").count == 1)
    }
    @Test func clientErrorsPermanentServerErrorsRetryable() {
        #expect(APIError.http(status: 502, code: nil).isRetryable)  // 5xx retryable
        #expect(APIError.http(status: 429, code: nil).isRetryable)
        #expect(!APIError.http(status: 400, code: "invalid_payload").isRetryable)
        #expect(!APIError.insecureScheme.isRetryable)
    }
    @Test func duplicateEventIsNotEnqueuedTwice() async throws {
        let api = MockAPI(); let (svc, store, _, _) = try make(api)
        let inc = Incident()
        await svc.submitInitial(inc, device: dev); await svc.submitInitial(inc, device: dev)
        #expect(api.calls.count == 1); #expect(try store.outbox().count == 1)
    }
    @Test func pendingAlertsAreSentWhenConnectivityReturns() async throws {
        let api = MockAPI(); api.script = [.failure(.network)]
        let (svc, store, _, _) = try make(api, delays: [])
        await svc.submitInitial(Incident(), device: dev)
        #expect(try store.outbox(state: "pending").count == 1)
        try store.updateOutbox(id: try store.outbox()[0].id, state: "pending", attempts: 1, next: Date(), error: nil)
        await svc.flush()
        #expect(try store.outbox(state: "accepted").count == 1)
    }
    @Test func testEmailSuccessAndFailure() async throws {
        let api = MockAPI(); let (svc, _, _, _) = try make(api)
        if case .success = await svc.sendTest(device: dev) {} else { Issue.record("expected success") }
        #expect(api.calls[0].path == "/v1/test-email")
        api.script = [.failure(.http(status: 401, code: nil))]
        if case .failure(let e) = await svc.sendTest(device: dev) { #expect(e == .http(status: 401, code: nil)) } else { Issue.record("expected failure") }
    }
    @Test func backendInfoReportsProviderAndMaskedRecipient() async throws {
        let api = MockAPI()
        api.script = [.success(APIResponse(status: 200, body: Data(#"{"provider":"brevo","fromEmail":"s***@x.com","recipient":"o***@gmail.com","recipientVerified":true,"pendingRecipient":null,"version":2}"#.utf8)))]
        let (svc, _, _, _) = try make(api)
        guard case .success(let info) = await svc.fetchBackendInfo() else { Issue.record("expected info"); return }
        #expect(info.provider == "brevo"); #expect(info.providerTitle == "Brevo"); #expect(info.recipient == "o***@gmail.com"); #expect(info.recipientVerified); #expect(info.pendingRecipient == nil)
        #expect(api.calls[0].path == "/v1/info")
        api.script = [.failure(.http(status: 401, code: nil))]
        if case .failure(let e) = await svc.fetchBackendInfo() { #expect(e == .http(status: 401, code: nil)) } else { Issue.record("expected failure") }
        api.script = [.success(APIResponse(status: 200, body: Data("{}".utf8)))]
        if case .success = await svc.fetchBackendInfo() { Issue.record("malformed info must fail") }
    }
    @Test func unverifiedRecipientIsReportedAsNotVerified() async throws {
        let api = MockAPI()
        api.script = [.success(APIResponse(status: 200, body: Data(#"{"provider":"brevo","recipient":null,"recipientVerified":false,"pendingRecipient":"g***@gmail.com","version":2}"#.utf8)))]
        let (svc, _, _, _) = try make(api)
        guard case .success(let info) = await svc.fetchBackendInfo() else { Issue.record("expected info"); return }
        #expect(info.recipient == nil); #expect(!info.recipientVerified); #expect(info.pendingRecipient == "g***@gmail.com")
    }
    @Test func configCallsSendExpectedBodiesToExpectedPaths() async throws {
        let api = MockAPI(); let (svc, _, _, _) = try make(api)
        _ = await svc.saveProvider("brevo", apiKey: "xkeysib-abcdefghij", fromEmail: "me@x.com")
        _ = await svc.requestRecipientCode(email: "me@gmail.com")
        _ = await svc.confirmRecipient(email: "me@gmail.com", code: "123456")
        #expect(api.calls.map(\.path) == ["/v1/config/provider", "/v1/config/recipient/request", "/v1/config/recipient/confirm"])
        let b0 = try #require(try JSONSerialization.jsonObject(with: api.calls[0].body) as? [String: String])
        #expect(b0 == ["provider": "brevo", "apiKey": "xkeysib-abcdefghij", "fromEmail": "me@x.com"])
        let b2 = try #require(try JSONSerialization.jsonObject(with: api.calls[2].body) as? [String: String])
        #expect(b2 == ["email": "me@gmail.com", "code": "123456"])
    }
    @Test func configFailuresHaveHumanMessagesAndNoKeyEcho() async throws {
        let api = MockAPI(); api.script = [.failure(.http(status: 400, code: "provider_key_rejected")), .failure(.http(status: 400, code: "code_invalid")), .failure(.http(status: 409, code: "no_verified_recipient"))]
        let (svc, _, _, _) = try make(api)
        let r1 = await svc.saveProvider("brevo", apiKey: "xkeysib-SECRETSECRET", fromEmail: "a@b.com")
        let r2 = await svc.confirmRecipient(email: "a@b.com", code: "000000")
        let r3 = await svc.sendTest(device: dev)
        var msgs: [String] = []
        if case .failure(let e) = r1 { msgs.append(e.userMessage) }
        if case .failure(let e) = r2 { msgs.append(e.userMessage) }
        if case .failure(let e) = r3 { msgs.append(e.userMessage) }
        #expect(msgs.count == 3)
        #expect(msgs[0].contains("Brevo rejected")); #expect(msgs[1].contains("wrong, expired")); #expect(msgs[2].contains("verify your Gmail") || msgs[2].contains("Verify your Gmail"))
        #expect(!msgs.joined().contains("SECRETSECRET"))
    }
    @Test func notEnrolledOrInvalidRecipientConfigSurfacesError() async throws {
        let c = APIClient(baseURL: "https://example.com", transport: URLSessionTransport(), secrets: InMemorySecrets())
        await #expect(throws: APIError.notEnrolled) { _ = try await c.post(path: "/v1/incidents", body: Data()) }
    }
}
