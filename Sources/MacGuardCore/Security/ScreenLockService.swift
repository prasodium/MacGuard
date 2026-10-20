import Foundation
import CoreGraphics

public protocol ScreenLocking: Sendable {
    func lock() async -> ActionStatus
}

/// Requests a lock by putting the display to sleep (`pmset displaysleepnow`, a supported CLI).
/// The session only locks if macOS is set to "Require password" after display sleep; we verify via
/// the public CGSession dictionary and report `requestedUnverified` otherwise. No private APIs.
public struct ScreenLockService: ScreenLocking {
    public init() {}

    public func lock() async -> ActionStatus {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        do {
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return .failed }
        } catch { return .failed }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return Self.isSessionLocked() ? .succeeded : .requestedUnverified
    }

    public static func isSessionLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? Int) == 1)
    }
}
