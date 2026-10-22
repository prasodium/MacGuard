import Foundation

public struct OutgoingMail: Equatable, Sendable {
    public var to: String, subject: String, html: String, text: String
    public init(to: String, subject: String, html: String, text: String) { self.to = to; self.subject = subject; self.html = html; self.text = text }
}

public protocol MailSending: Sendable {
    var isConfigured: Bool { get }
    /// Returns the provider's message id. "Accepted" only: inbox delivery is not confirmed.
    func send(_ mail: OutgoingMail) async throws -> String
    /// Checks the saved key without sending anything.
    func verifyKey() async throws
}

/// Thread-safe holder for values the mailer needs that the UI edits (sender address, verified recipient).
public final class MailConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var _sender = "", _recipient: String?
    public init(sender: String = "", recipient: String? = nil) { _sender = sender; _recipient = recipient }
    public var sender: String { get { lock.lock(); defer { lock.unlock() }; return _sender } set { lock.lock(); _sender = newValue; lock.unlock() } }
    public var recipient: String? { get { lock.lock(); defer { lock.unlock() }; return _recipient } set { lock.lock(); _recipient = newValue; lock.unlock() } }
}

/// Sends email directly through Brevo's transactional HTTP API. The API key lives only in the Keychain.
public final class BrevoMailer: MailSending, @unchecked Sendable {
    public static let keyAccount = "brevo-api-key"
    private let transport: HTTPTransport
    private let secrets: SecretStoring
    private let config: MailConfig
    private let baseURL: String

    public init(transport: HTTPTransport = URLSessionTransport(), secrets: SecretStoring, config: MailConfig,
                baseURL: String = "https://api.brevo.com") {
        self.transport = transport; self.secrets = secrets; self.config = config; self.baseURL = baseURL
    }

    public var hasKey: Bool { secrets.get(Self.keyAccount) != nil }
    public var isConfigured: Bool { hasKey && !config.sender.isEmpty }
    public func saveKey(_ key: String) -> Bool { secrets.set(Self.keyAccount, Data(key.utf8)) }
    public func removeKey() { secrets.delete(Self.keyAccount) }

    private func key() throws -> String {
        guard let d = secrets.get(Self.keyAccount), let k = String(data: d, encoding: .utf8), !k.isEmpty else { throw APIError.notConfigured }
        return k
    }

    private func url(_ path: String) throws -> URL {
        guard let c = URLComponents(string: baseURL + path), c.scheme == "https", c.host != nil, let u = c.url else { throw APIError.insecureScheme }
        return u
    }

    /// "Name <a@b.c>" → name + email (Brevo wants them separately).
    static func parseSender(_ s: String) -> [String: String] {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let lt = t.lastIndex(of: "<"), t.hasSuffix(">") else { return ["email": t] }
        let email = t[t.index(after: lt)..<t.index(before: t.endIndex)].trimmingCharacters(in: .whitespaces)
        let name = t[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return name.isEmpty ? ["email": email] : ["name": name, "email": email]
    }

    private func perform(_ req: URLRequest) async throws -> APIResponse {
        let r = try await transport.send(req)
        guard (200..<300).contains(r.status) else { throw APIError.http(status: r.status, code: r.json?["code"] as? String) }
        return r
    }

    public func send(_ mail: OutgoingMail) async throws -> String {
        let apiKey = try key()
        guard !config.sender.isEmpty else { throw APIError.notConfigured }
        var req = URLRequest(url: try url("/v3/smtp/email"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "sender": Self.parseSender(config.sender), "to": [["email": mail.to]],
            "subject": mail.subject, "htmlContent": mail.html, "textContent": mail.text,
        ] as [String: Any])
        let r = try await perform(req)
        return (r.json?["messageId"] as? String) ?? "accepted"
    }

    public func verifyKey() async throws {
        var req = URLRequest(url: try url("/v3/account"))
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue(try key(), forHTTPHeaderField: "api-key")
        _ = try await perform(req)
    }
}
