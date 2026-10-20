import Foundation
import CryptoKit
import Security

public enum VerificationError: Error, Equatable {
    case invalidEmail, tooManyRequests, codeInvalid
    public var userMessage: String {
        switch self {
        case .invalidEmail: return "That email address does not look valid."
        case .tooManyRequests: return "Too many codes requested. Try again in an hour."
        case .codeInvalid: return "That code is wrong, expired, or was tried too many times. Request a new code."
        }
    }
}

/// Proves the owner can read mail at an address before alerts are sent there: a random 6-digit code is emailed
/// (via Brevo) and must be typed back. Only a salted hash of the code is kept; codes expire after 15 minutes
/// and lock after 5 wrong attempts. State lives in the local SQLite store.
public final class RecipientVerifier: @unchecked Sendable {
    private struct Pending: Codable { var email: String, salt: String, hash: String, expires: Double, attempts: Int }
    private let store: SecurityEventStore
    private let mailer: MailSending
    private let now: @Sendable () -> Date
    private let pendingKey = "recipient.pending", requestsKey = "recipient.requests"
    public static let codeLifetime: TimeInterval = 15 * 60, maxAttempts = 5, maxRequestsPerHour = 3

    public init(store: SecurityEventStore, mailer: MailSending, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.mailer = mailer; self.now = now
    }

    public static func normalized(_ email: String) -> String? {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let re = #"^[^\s@<>"',;]{1,64}@[^\s@<>"',;]{1,190}\.[^\s@<>"',;]{2,24}$"#
        return e.count <= 254 && e.range(of: re, options: .regularExpression) != nil ? e : nil
    }

    public var pendingEmail: String? {
        guard let p = loadPending(), p.expires > now().timeIntervalSince1970 else { return nil }
        return p.email
    }

    private func loadPending() -> Pending? { ((try? store.value(pendingKey)) ?? nil).flatMap { try? JSONDecoder().decode(Pending.self, from: $0) } }
    private func savePending(_ p: Pending?) { try? store.setValue(pendingKey, p.flatMap { try? JSONEncoder().encode($0) }) }
    private func hash(_ code: String, _ email: String, _ salt: String) -> String {
        SHA256.hash(data: Data("\(salt):\(email):\(code)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func randomCode() -> String {
        var n: UInt32 = 0
        repeat { _ = SecRandomCopyBytes(kSecRandomDefault, 4, &n) } while n >= 4_000_000_000 // avoid modulo bias
        return String(format: "%06d", n % 1_000_000)
    }

    /// Emails a fresh code. Nothing is sent to the address for alerts until `confirm` succeeds.
    public func requestCode(email raw: String) async throws {
        guard let email = Self.normalized(raw) else { throw VerificationError.invalidEmail }
        let t = now().timeIntervalSince1970
        var times = ((try? store.value(requestsKey)) ?? nil).flatMap { try? JSONDecoder().decode([Double].self, from: $0) } ?? []
        times = times.filter { t - $0 < 3600 }
        guard times.count < Self.maxRequestsPerHour else { throw VerificationError.tooManyRequests }
        let code = Self.randomCode(), salt = UUID().uuidString
        let r = EmailTemplates.verification(code: code)
        _ = try await mailer.send(OutgoingMail(to: email, subject: r.subject, html: r.html, text: r.text))
        times.append(t); try? store.setValue(requestsKey, try? JSONEncoder().encode(times))
        savePending(Pending(email: email, salt: salt, hash: hash(code, email, salt), expires: t + Self.codeLifetime, attempts: 0))
    }

    /// Returns the verified, normalized address, or throws `codeInvalid`.
    public func confirm(email raw: String, code: String) throws -> String {
        guard let email = Self.normalized(raw), var p = loadPending(), p.email == email,
              p.expires > now().timeIntervalSince1970, p.attempts < Self.maxAttempts else { throw VerificationError.codeInvalid }
        p.attempts += 1; savePending(p)
        guard hash(code.trimmingCharacters(in: .whitespaces), email, p.salt) == p.hash else { throw VerificationError.codeInvalid }
        savePending(nil)
        return email
    }
}
