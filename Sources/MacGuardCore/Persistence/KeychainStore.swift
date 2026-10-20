import Foundation
import Security

public protocol SecretStoring: Sendable {
    func get(_ account: String) -> Data?
    func set(_ account: String, _ value: Data) -> Bool
    func delete(_ account: String)
}

/// Generic-password Keychain storage (used for the Brevo API key).
public struct KeychainStore: SecretStoring {
    let service: String
    public init(service: String = "com.harprosad.macguard") { self.service = service }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public func get(_ account: String) -> Data? {
        var q = base(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    public func set(_ account: String, _ value: Data) -> Bool {
        delete(account)
        var q = base(account); q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
    public func delete(_ account: String) { SecItemDelete(base(account) as CFDictionary) }
}

public final class InMemorySecrets: SecretStoring, @unchecked Sendable {
    private var d: [String: Data] = [:]; private let l = NSLock()
    public init() {}
    public func get(_ a: String) -> Data? { l.lock(); defer { l.unlock() }; return d[a] }
    public func set(_ a: String, _ v: Data) -> Bool { l.lock(); defer { l.unlock() }; d[a] = v; return true }
    public func delete(_ a: String) { l.lock(); defer { l.unlock() }; d[a] = nil }
}
