import Foundation

public enum APIError: Error, Equatable {
    case invalidURL, insecureScheme, notEnrolled, network, timeout
    case http(status: Int, code: String?)
    public var isRetryable: Bool {
        switch self {
        case .network, .timeout: return true
        case .http(let s, _): return s == 408 || s == 429 || s >= 500
        default: return false
        }
    }
    public var userMessage: String {
        switch self {
        case .invalidURL: return "The backend address is not valid."
        case .insecureScheme: return "The backend address must use HTTPS."
        case .notEnrolled: return "This Mac is not enrolled with the alert backend yet."
        case .network: return "Network unavailable."
        case .timeout: return "The alert backend did not respond in time."
        case .http(let s, let c):
            switch s {
            case 401, 403: return "The backend rejected this Mac's credentials. Re-enroll in Settings."
            case 400, 422: return "The backend rejected the alert data (\(c ?? "invalid"))."
            case 429: return "Rate limited by the backend."
            case 502, 503: return "The email provider or backend is temporarily unavailable."
            default: return "Backend error (\(s))."
            }
        }
    }
}

public struct APIResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
    public var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> APIResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(timeout: TimeInterval = 15) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout; c.timeoutIntervalForResource = timeout * 2
        c.waitsForConnectivity = false
        session = URLSession(configuration: c)
    }
    public func send(_ request: URLRequest) async throws -> APIResponse {
        do {
            let (data, resp) = try await session.data(for: request)
            return APIResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch let e as URLError where e.code == .timedOut { throw APIError.timeout }
        catch { throw APIError.network }
    }
}

public protocol AlertAPI: Sendable {
    func post(path: String, body: Data) async throws -> APIResponse
    func enroll(token: String, deviceName: String) async throws
    var isEnrolled: Bool { get }
}

public final class APIClient: AlertAPI, @unchecked Sendable {
    private let baseURL: String
    private let transport: HTTPTransport
    private let secrets: SecretStoring
    private let allowLocalHTTP: Bool

    static let installKey = "installation-id", secretKey = "installation-secret"

    public init(baseURL: String, transport: HTTPTransport = URLSessionTransport(), secrets: SecretStoring,
                allowLocalHTTP: Bool = false) {
        self.baseURL = baseURL; self.transport = transport; self.secrets = secrets; self.allowLocalHTTP = allowLocalHTTP
    }

    public var isEnrolled: Bool { secrets.get(Self.installKey) != nil && secrets.get(Self.secretKey) != nil }
    public var installationID: String? { secrets.get(Self.installKey).flatMap { String(data: $0, encoding: .utf8) } }

    func url(_ path: String) throws -> URL {
        guard var c = URLComponents(string: baseURL), let host = c.host, !host.isEmpty else { throw APIError.invalidURL }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard c.scheme == "https" || (allowLocalHTTP && local && c.scheme == "http") else { throw APIError.insecureScheme }
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        guard let u = c.url else { throw APIError.invalidURL }
        return u
    }

    public func enroll(token: String, deviceName: String) async throws {
        let id = secrets.get(Self.installKey).flatMap { String(data: $0, encoding: .utf8) } ?? UUID().uuidString
        let secret = RequestAuthenticator.newSecret()
        let body = try JSONSerialization.data(withJSONObject: [
            "enrollmentToken": token, "installationId": id,
            "secret": secret.base64EncodedString(), "deviceName": String(deviceName.prefix(64)),
        ])
        var req = URLRequest(url: try url("/v1/enroll"))
        req.httpMethod = "POST"; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let r = try await transport.send(req)
        guard (200..<300).contains(r.status) else { throw APIError.http(status: r.status, code: r.json?["error"] as? String) }
        _ = secrets.set(Self.installKey, Data(id.utf8)); _ = secrets.set(Self.secretKey, secret)
    }

    public func post(path: String, body: Data) async throws -> APIResponse {
        guard let idData = secrets.get(Self.installKey), let id = String(data: idData, encoding: .utf8),
              let secret = secrets.get(Self.secretKey) else { throw APIError.notEnrolled }
        var req = URLRequest(url: try url(path))
        req.httpMethod = "POST"; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in RequestAuthenticator(installationID: id, secret: secret).sign(method: "POST", path: path, body: body) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let r = try await transport.send(req)
        guard (200..<300).contains(r.status) else { throw APIError.http(status: r.status, code: r.json?["error"] as? String) }
        return r
    }

    public func unenroll() { secrets.delete(Self.secretKey); secrets.delete(Self.installKey) }
}
