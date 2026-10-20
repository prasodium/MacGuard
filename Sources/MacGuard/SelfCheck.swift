import Foundation
import AppKit
import MacGuardCore

/// `MacGuard --self-check`: real-hardware smoke test of the platform integrations that do not need
/// user interaction. Prints facts only; it never fakes a success.
enum SelfCheck {
    @MainActor static func runAndExit() -> Never {
        var failures = 0
        func report(_ name: String, _ ok: Bool, _ detail: String) { print("[\(ok ? "PASS" : "FAIL")] \(name): \(detail)"); if !ok { failures += 1 } }
        do {
            let s = try IOKitPowerReader().read()
            report("power-read", s.external != .unknown, "\(s.summary), battery \(s.batteryPercent.map(String.init) ?? "n/a")%, hasBattery=\(s.hasBattery)")
        } catch { report("power-read", false, "\(error)") }

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mg-selfcheck-\(UUID().uuidString)/db.sqlite")
        if let st = try? SecurityEventStore(path: path) {
            let e = SecurityEvent(type: .testEvent, result: "selfcheck", isTest: true)
            try? st.append(e)
            let ok = ((try? st.events())?.first?.id == e.id)
            let perms = (try? FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int) ?? 0
            report("sqlite-roundtrip", ok, "perms=\(String(perms, radix: 8))")
            report("db-file-permissions-0600", perms == 0o600, "")
            try? FileManager.default.removeItem(at: path.deletingLastPathComponent())
        } else { report("sqlite-roundtrip", false, "open failed") }

        let kc = KeychainStore(service: "com.harprosad.macguard.selfcheck")
        let wrote = kc.set("t", Data("x".utf8)); let read = kc.get("t") == Data("x".utf8); kc.delete("t")
        report("keychain-roundtrip", wrote && read, "write=\(wrote) read=\(read)")

        let loc = CoreLocationProvider()
        print("[INFO] location-authorization: \(loc.authorization.rawValue) (bundle id: \(Bundle.main.bundleIdentifier ?? "none"))")
        print("[INFO] screen-locked-now: \(ScreenLockService.isSessionLocked())")

        let sounds = SystemSoundPlayer.availableSounds.filter { NSSound(named: NSSound.Name($0)) != nil }
        report("alarm-sounds-available", sounds.count == SystemSoundPlayer.availableSounds.count, sounds.joined(separator: ","))
        if CommandLine.arguments.contains("--lock-test") {
            // WARNING: really locks this session. Run only when you are ready to type your password.
            let sem = DispatchSemaphore(value: 0); var result = ActionStatus.notStarted
            Task { @MainActor in result = await ScreenLockService().lock(); sem.signal() }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            report("screen-lock", result == .succeeded, "result=\(result.rawValue)")
        }
        if CommandLine.arguments.contains("--play") {
            let p = SystemSoundPlayer(); let ok = p.play(named: "Sosumi")
            RunLoop.current.run(until: Date().addingTimeInterval(1.5)); p.stopAll()
            report("alarm-playback-started", ok, "NSSound.play() returned \(ok); audibility not machine-verifiable")
        }
        print(failures == 0 ? "SELF-CHECK OK" : "SELF-CHECK FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
