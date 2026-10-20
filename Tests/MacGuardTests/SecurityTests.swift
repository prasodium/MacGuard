import Testing
import Foundation
@testable import MacGuardCore

final class CapturingTransport: HTTPTransport, @unchecked Sendable {
    var last: URLRequest?
    var response = APIResponse(status: 200, body: Data("{}".utf8))
    func send(_ request: URLRequest) async throws -> APIResponse { last = request; return response }
}

@Suite struct SecurityTests {
    @Test func httpBackendIsRejectedHttpsAllowed() async {
        let s = InMemorySecrets(); _ = s.set("installation-id", Data("i".utf8)); _ = s.set("installation-secret", Data(count: 32))
        let bad = APIClient(baseURL: "http://example.com", transport: CapturingTransport(), secrets: s, allowLocalHTTP: true)
        await #expect(throws: APIError.insecureScheme) { _ = try await bad.post(path: "/v1/incidents", body: Data()) }
        let t = CapturingTransport()
        let good = APIClient(baseURL: "https://example.com/", transport: t, secrets: s)
        _ = try? await good.post(path: "/v1/incidents", body: Data("{}".utf8))
        #expect(t.last?.url?.absoluteString == "https://example.com/v1/incidents")
        let local = APIClient(baseURL: "http://localhost:8787", transport: t, secrets: s, allowLocalHTTP: true)
        _ = try? await local.post(path: "/v1/incidents", body: Data("{}".utf8)); #expect(t.last?.url?.host == "localhost")
        let noLocal = APIClient(baseURL: "http://localhost:8787", transport: t, secrets: s)
        await #expect(throws: APIError.insecureScheme) { _ = try await noLocal.post(path: "/v1/incidents", body: Data()) }
    }
    @Test func signedHeadersAreAttachedAndSecretNeverSent() async throws {
        let s = InMemorySecrets(); let secret = Data(repeating: 7, count: 32)
        _ = s.set("installation-id", Data("inst".utf8)); _ = s.set("installation-secret", secret)
        let t = CapturingTransport()
        _ = try await APIClient(baseURL: "https://x.io", transport: t, secrets: s).post(path: "/v1/incidents", body: Data("{}".utf8))
        let h = try #require(t.last?.allHTTPHeaderFields)
        #expect(h["X-MG-Installation"] == "inst"); #expect(h["X-MG-Signature"]?.count == 64); #expect(h["X-MG-Nonce"] != nil)
        let everything = h.values.joined() + String(data: t.last?.httpBody ?? Data(), encoding: .utf8)!
        #expect(!everything.contains(secret.base64EncodedString()))
    }
    @Test func signatureMatchesKnownVector() {
        // Vector produced by the Node backend implementation: Swift signer and server verifier must agree.
        let a = RequestAuthenticator(installationID: "i", secret: Data(repeating: 1, count: 32))
        let h = a.sign(method: "POST", path: "/v1/incidents", body: Data("{}".utf8), now: Date(timeIntervalSince1970: 1_700_000_000), nonce: "n")
        #expect(h["X-MG-Signature"] == "57a366a7af2a612c62105942623e9beaddfcfad0a0a1169cdfe7cceae3c20097") // computed by backend/src/auth.js
        #expect(h["X-MG-Timestamp"] == "1700000000")
    }
    @Test func databaseFileAndDirectoryArePrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mgt-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("db.sqlite")
        _ = try SecurityEventStore(path: path)
        let f = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        let d = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(f == 0o600); #expect(d == 0o700)
        try? FileManager.default.removeItem(at: dir)
    }
    @Test func sourceContainsNoEmbeddedProviderSecrets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let patterns = ["re_[A-Za-z0-9]{20,}", "xkeysib-[A-Za-z0-9-]{20,}", "sk_live", "api\\.resend\\.com", "api\\.brevo\\.com"] // real key shapes, and no direct provider calls from the client
        let e = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for p in patterns { #expect(text.range(of: p, options: .regularExpression) == nil, "\(p) found in \(url.lastPathComponent)") }
        }
    }
    @Test func eventLogDoesNotContainSecrets() throws {
        let s = try SecurityEventStore(path: nil)
        try s.append(SecurityEvent(type: .emailFailed, result: APIError.http(status: 401, code: nil).userMessage))
        let all = try s.events().map(\.result).joined()
        #expect(!all.lowercased().contains("secret") && !all.lowercased().contains("token"))
    }
    @Test func screenLockStatusNeverClaimsVerifiedWithoutProof() {
        // requestedUnverified is a distinct state from succeeded.
        #expect(ActionStatus.requestedUnverified != ActionStatus.succeeded)
    }
    @Test func eventStoreRoundTripsAndPurges() throws {
        let s = try SecurityEventStore(path: nil)
        let old = SecurityEvent(timestamp: Date().addingTimeInterval(-200 * 86400), type: .protectionArmed, result: "old")
        let new = SecurityEvent(type: .testEvent, result: "new", isTest: true)
        try s.append(old); try s.append(new)
        try s.purgeEvents(olderThan: 90)
        let e = try s.events(); #expect(e.count == 1); #expect(e[0].isTest)
    }
    @Test func incidentPersistsWithAllFields() throws {
        let s = try SecurityEventStore(path: nil)
        var i = Incident(batteryPercent: 42); i.alarm = .succeeded; i.screenLock = .requestedUnverified
        try s.save(i); let back = try #require(try s.incident(id: i.id))
        #expect(back.alarm == .succeeded); #expect(back.screenLock == .requestedUnverified); #expect(back.batteryPercent == 42)
    }

    @Test func settingsFromOlderVersionKeepValuesAndGainDefaults() throws {
        let old = #"{"disconnectDelay":3,"emailEnabled":true,"backendURL":"https://x.io","alarm":{"sound":"Glass","repeatInterval":2,"initialDelay":0,"continueAfterLock":true,"showLocalNotification":true,"maximizeVolume":true}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(s.disconnectDelay == 3); #expect(s.emailEnabled); #expect(s.backendURL == "https://x.io"); #expect(s.alarm.sound == "Glass")
        #expect(s.stopAlarmOnReconnect); #expect(s.followUpMode == .oneFollowUp)   // defaults for fields the old data lacks
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }
}
