import Foundation
import LocalAuthentication

public protocol OwnerAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

/// Uses the system LocalAuthentication prompt (Touch ID / macOS account password).
/// MacGuard never sees or stores the password. If the Mac has no authentication
/// configured at all, returns true so the owner is never locked out of their own machine.
public struct OwnerAuthenticationService: OwnerAuthenticating {
    public init() {}
    public func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { return false }
    }
}
