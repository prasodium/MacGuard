import Foundation
import CoreGraphics

public protocol ScreenLocking: Sendable {
    func lock() async -> ActionStatus
}

/// Locks the current login session.
///
/// macOS has no public API for "lock the screen now". Mechanisms, in order:
/// 1. `SACLockScreenImmediate` from login.framework, resolved at runtime with `dlopen`/`dlsym`. This is a
///    **private** symbol: it is what the system's own "Lock Screen" command uses and is long-stable, but
///    Apple could change it and it would make an App Store submission unacceptable (MacGuard is not
///    distributed through the App Store). If it is missing, we fall through instead of crashing.
/// 2. `pmset displaysleepnow` (public CLI). Sleeps the display; the session locks only if macOS is set to
///    require a password immediately afterwards.
/// Success is reported only when `CGSession` says the screen is locked; otherwise `requestedUnverified`.
public struct ScreenLockService: ScreenLocking {
    public init() {}

    public func lock() async -> ActionStatus {
        var requested = Self.callSACLockScreenImmediate()
        if await Self.waitUntilLocked(seconds: 1.5) { return .succeeded }
        if Self.runDisplaySleep() { requested = true }
        if await Self.waitUntilLocked(seconds: 2.0) { return .succeeded }
        return requested ? .requestedUnverified : .failed
    }

    static func callSACLockScreenImmediate() -> Bool {
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let sym = dlsym(h, "SACLockScreenImmediate") else { return false }
        typealias Fn = @convention(c) () -> Int32
        _ = unsafeBitCast(sym, to: Fn.self)()
        return true
    }

    static func runDisplaySleep() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    static func waitUntilLocked(seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if isSessionLocked() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        } while Date() < deadline
        return isSessionLocked()
    }

    public static func isSessionLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let b = d["CGSSessionScreenIsLocked"] as? Bool { return b }
        return (d["CGSSessionScreenIsLocked"] as? Int) == 1
    }
}
