import Foundation
import CryptoKit

/// HMAC-SHA256 request signing with a per-installation secret (never a global key).
/// canonical = METHOD \n PATH \n TIMESTAMP \n NONCE \n SHA256(body)
public struct RequestAuthenticator: Sendable {
    public let installationID: String
    private let secret: Data
    public init(installationID: String, secret: Data) { self.installationID = installationID; self.secret = secret }

    public static func canonical(method: String, path: String, timestamp: String, nonce: String, body: Data) -> String {
        let h = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return [method.uppercased(), path, timestamp, nonce, h].joined(separator: "\n")
    }

    public func sign(method: String, path: String, body: Data, now: Date = Date(), nonce: String = UUID().uuidString) -> [String: String] {
        let ts = String(Int(now.timeIntervalSince1970))
        let c = Self.canonical(method: method, path: path, timestamp: ts, nonce: nonce, body: body)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(c.utf8), using: SymmetricKey(data: secret))
        return ["X-MG-Installation": installationID, "X-MG-Timestamp": ts, "X-MG-Nonce": nonce,
                "X-MG-Signature": Data(mac).map { String(format: "%02x", $0) }.joined()]
    }

    public static func newSecret() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }
}
