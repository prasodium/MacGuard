import Testing
import Foundation
@testable import MacGuardCore

final class CapturingTransport: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var response = APIResponse(status: 201, body: Data(#"{"messageId":"<abc@brevo>"}"#.utf8))
    var error: APIError?
    func send(_ request: URLRequest) async throws -> APIResponse {
        requests.append(request)
        if let error { throw error }
        return response
    }
}

@Suite struct BrevoMailerTests {
    func make(_ t: CapturingTransport, key: String? = "xkeysib-test-key-123", sender: String = "MacGuard <me@example.com>", base: String = "https://api.brevo.com") -> BrevoMailer {
        let s = InMemorySecrets(); if let key { _ = s.set(BrevoMailer.keyAccount, Data(key.utf8)) }
        return BrevoMailer(transport: t, secrets: s, config: MailConfig(sender: sender), baseURL: base)
    }
    let mail = OutgoingMail(to: "owner@gmail.com", subject: "Subj", html: "<p>h</p>", text: "t")

    @Test func sendsExpectedRequestToBrevo() async throws {
        let t = CapturingTransport(); let id = try await make(t).send(mail)
        #expect(id == "<abc@brevo>")
        let r = try #require(t.requests.first)
        #expect(r.url?.absoluteString == "https://api.brevo.com/v3/smtp/email"); #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "api-key") == "xkeysib-test-key-123")
        #expect(r.value(forHTTPHeaderField: "content-type") == "application/json")
        let b = try #require(try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
        #expect((b["sender"] as? [String: String]) == ["name": "MacGuard", "email": "me@example.com"])
        #expect((b["to"] as? [[String: String]]) == [["email": "owner@gmail.com"]])
        #expect(b["subject"] as? String == "Subj"); #expect(b["htmlContent"] as? String == "<p>h</p>"); #expect(b["textContent"] as? String == "t")
    }
    @Test func plainSenderAddress() async throws {
        let t = CapturingTransport(); _ = try await make(t, sender: "me@example.com").send(mail)
        let b = try #require(try JSONSerialization.jsonObject(with: t.requests[0].httpBody ?? Data()) as? [String: Any])
        #expect((b["sender"] as? [String: String]) == ["email": "me@example.com"])
    }
    @Test func refusesWithoutKeyOrSender() async {
        let t = CapturingTransport()
        await #expect(throws: APIError.notConfigured) { _ = try await make(t, key: nil).send(mail) }
        await #expect(throws: APIError.notConfigured) { _ = try await make(t, sender: "").send(mail) }
        #expect(t.requests.isEmpty)
    }
    @Test func neverUsesPlainHTTP() async {
        let t = CapturingTransport()
        await #expect(throws: APIError.insecureScheme) { _ = try await make(t, base: "http://api.brevo.com").send(mail) }
        #expect(t.requests.isEmpty)
    }
    @Test func httpErrorsBecomeTypedErrors() async {
        let t = CapturingTransport(); t.response = APIResponse(status: 401, body: Data(#"{"code":"unauthorized","message":"Key not found"}"#.utf8))
        await #expect(throws: APIError.http(status: 401, code: "unauthorized")) { _ = try await make(t).send(mail) }
        #expect(APIError.http(status: 401, code: "unauthorized").userMessage.contains("rejected the key"))
        #expect(APIError.http(status: 400, code: nil).userMessage.contains("sender"))
    }
    @Test func transportFailuresPropagate() async {
        let t = CapturingTransport(); t.error = .network
        await #expect(throws: APIError.network) { _ = try await make(t).send(mail) }
    }
    @Test func verifyKeyUsesAccountEndpointAndSendsNothing() async throws {
        let t = CapturingTransport(); t.response = APIResponse(status: 200, body: Data("{}".utf8))
        try await make(t).verifyKey()
        #expect(t.requests.count == 1); #expect(t.requests[0].url?.path == "/v3/account"); #expect(t.requests[0].httpMethod == "GET")
        t.response = APIResponse(status: 401, body: Data("{}".utf8))
        await #expect(throws: APIError.http(status: 401, code: nil)) { try await make(t).verifyKey() }
    }
    @Test func keyIsStoredInSecretStoreAndCanBeRemoved() {
        let s = InMemorySecrets(); let m = BrevoMailer(transport: CapturingTransport(), secrets: s, config: MailConfig(sender: "a@b.com"))
        #expect(!m.isConfigured); #expect(m.saveKey("xkeysib-abcdefghij")); #expect(m.isConfigured)
        #expect(s.get(BrevoMailer.keyAccount) == Data("xkeysib-abcdefghij".utf8))
        m.removeKey(); #expect(!m.hasKey)
    }
}
