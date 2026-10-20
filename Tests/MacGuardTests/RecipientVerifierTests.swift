import Testing
import Foundation
@testable import MacGuardCore

final class Clock: @unchecked Sendable { var t = Date(); func advance(_ s: TimeInterval) { t = t.addingTimeInterval(s) } }

@Suite struct RecipientVerifierTests {
    func make() throws -> (RecipientVerifier, MockMailer, SecurityEventStore, Clock) {
        let m = MockMailer(), s = try SecurityEventStore(path: nil), c = Clock()
        return (RecipientVerifier(store: s, mailer: m, now: { c.t }), m, s, c)
    }
    func code(_ m: MockMailer) -> String {
        let r = try! NSRegularExpression(pattern: #"code is (\d{6})"#); let t = m.sent.last!.text
        return String(t[Range(r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))!.range(at: 1), in: t)!])
    }

    @Test func emailedCodeVerifiesTheAddress() async throws {
        let (v, m, _, _) = try make()
        try await v.requestCode(email: " Me@Gmail.com ")
        #expect(m.sent.count == 1); #expect(m.sent[0].to == "me@gmail.com"); #expect(m.sent[0].subject.contains("verification code"))
        #expect(v.pendingEmail == "me@gmail.com")
        #expect(try v.confirm(email: "me@gmail.com", code: code(m)) == "me@gmail.com")
        #expect(v.pendingEmail == nil)
    }
    @Test func wrongCodeWrongAddressAndReuseAreRejected() async throws {
        let (v, m, _, _) = try make()
        try await v.requestCode(email: "me@gmail.com"); let good = code(m); let bad = good == "000000" ? "111111" : "000000"
        #expect(throws: VerificationError.codeInvalid) { _ = try v.confirm(email: "me@gmail.com", code: bad) }
        #expect(throws: VerificationError.codeInvalid) { _ = try v.confirm(email: "other@gmail.com", code: good) }
        _ = try v.confirm(email: "me@gmail.com", code: good)
        #expect(throws: VerificationError.codeInvalid) { _ = try v.confirm(email: "me@gmail.com", code: good) }   // single use
    }
    @Test func codeExpiresAfterFifteenMinutes() async throws {
        let (v, m, _, c) = try make()
        try await v.requestCode(email: "me@gmail.com"); let k = code(m)
        c.advance(16 * 60)
        #expect(throws: VerificationError.codeInvalid) { _ = try v.confirm(email: "me@gmail.com", code: k) }
        #expect(v.pendingEmail == nil)
    }
    @Test func locksAfterFiveWrongAttempts() async throws {
        let (v, m, _, _) = try make()
        try await v.requestCode(email: "me@gmail.com"); let good = code(m); let bad = good == "123456" ? "654321" : "123456"
        for _ in 0..<5 { _ = try? v.confirm(email: "me@gmail.com", code: bad) }
        #expect(throws: VerificationError.codeInvalid) { _ = try v.confirm(email: "me@gmail.com", code: good) }
    }
    @Test func codeIsStoredOnlyAsAHash() async throws {
        let (v, m, s, _) = try make()
        try await v.requestCode(email: "me@gmail.com")
        let raw = String(data: try #require(try s.value("recipient.pending")), encoding: .utf8)!
        #expect(!raw.contains(code(m)))
    }
    @Test func rateLimitsCodeRequestsPerHour() async throws {
        let (v, _, _, c) = try make()
        for _ in 0..<3 { try await v.requestCode(email: "a@gmail.com") }
        await #expect(throws: VerificationError.tooManyRequests) { try await v.requestCode(email: "a@gmail.com") }
        c.advance(3601); try await v.requestCode(email: "a@gmail.com")
    }
    @Test func invalidAddressesAreRejectedBeforeSendingAnything() async throws {
        let (v, m, _, _) = try make()
        for bad in ["", "nope", "a@b", "a b@c.com", "a@b.c", "<x>@y.com"] {
            await #expect(throws: VerificationError.invalidEmail) { try await v.requestCode(email: bad) }
        }
        #expect(m.sent.isEmpty)
    }
    @Test func mailFailureDoesNotCreateAPendingCode() async throws {
        let (v, m, _, _) = try make(); m.script = [.failure(.http(status: 400, code: nil))]
        await #expect(throws: APIError.http(status: 400, code: nil)) { try await v.requestCode(email: "me@gmail.com") }
        #expect(v.pendingEmail == nil)
    }
    @Test func codesAreSixDigitsAndVary() {
        let codes = Set((0..<50).map { _ in RecipientVerifier.randomCode() })
        #expect(codes.allSatisfy { $0.count == 6 && $0.allSatisfy(\.isNumber) }); #expect(codes.count > 40)
    }
}
