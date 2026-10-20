import Foundation

public enum APIError: Error, Equatable {
    case invalidURL, insecureScheme, notConfigured, noRecipient, network, timeout
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
        case .invalidURL: return "The email service address is not valid."
        case .insecureScheme: return "The email service must use HTTPS."
        case .notConfigured: return "No Brevo key is saved yet. Add it in Settings → Email."
        case .noRecipient: return "No verified alert address yet. Verify your Gmail in Settings → Email."
        case .network: return "No internet connection."
        case .timeout: return "Brevo did not respond in time."
        case .http(let s, _):
            switch s {
            case 401, 403: return "Brevo rejected the key. Save a fresh key in Settings → Email."
            case 400, 422: return "Brevo rejected the email. Check that the sender address is verified in Brevo."
            case 402: return "Your Brevo plan cannot send more email right now."
            case 429: return "Brevo rate limit reached. Try again later."
            case 500...599: return "Brevo is temporarily unavailable."
            default: return "Brevo error (\(s))."
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

public extension APIError {
    /// Maps any thrown error to a user-facing sentence (never raw system text).
    static func message(for error: Error) -> String { (error as? APIError)?.userMessage ?? "Something went wrong." }
}
