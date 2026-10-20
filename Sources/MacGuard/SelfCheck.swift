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
        if let i = CommandLine.arguments.firstIndex(of: "--e2e"), CommandLine.arguments.count > i + 2 {
            let url = CommandLine.arguments[i + 1], token = CommandLine.arguments[i + 2]
            let sem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let api = APIClient(baseURL: url, secrets: InMemorySecrets(), allowLocalHTTP: true)
                let dev = DeviceInfo.current()
                do {
                    try await api.enroll(token: token, deviceName: dev.name)
                    report("e2e-enroll", api.isEnrolled, "enrolled=\(api.isEnrolled)")
                    guard let store = try? SecurityEventStore(path: nil) else { sem.signal(); return }
                    let n = TheftNotificationService(api: api, store: store)
                    if let li = CommandLine.arguments.firstIndex(of: "--mail-log"), CommandLine.arguments.count > li + 1 {
                        let logPath = CommandLine.arguments[li + 1]
                        func lastMail() -> [String: Any]? {
                            guard let t = try? String(contentsOfFile: logPath, encoding: .utf8), let l = t.split(separator: "\n").last else { return nil }
                            return (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any]
                        }
                        let me = "owner.e2e@gmail.com"
                        let bad = await n.saveProvider("brevo", apiKey: "xkeysib-WRONG-key-12345", fromEmail: "sender@example.com")
                        if case .failure(let e) = bad { report("e2e-wrong-brevo-key-rejected", e.userMessage.contains("rejected"), e.userMessage) } else { report("e2e-wrong-brevo-key-rejected", false, "accepted a bad key") }
                        let saved = await n.saveProvider("brevo", apiKey: "xkeysib-e2e-test-key-123", fromEmail: "sender@example.com")
                        report("e2e-save-brevo-key", { if case .success = saved { return true } else { return false } }(), "")
                        let before: Result<Void, APIError> = await n.requestRecipientCode(email: me)
                        report("e2e-request-code", { if case .success = before { return true } else { return false } }(), "")
                        if case .success(let i0) = await n.fetchBackendInfo() { report("e2e-unverified-until-code", i0.pendingRecipient != nil && !i0.recipientVerified, "pending=\(i0.pendingRecipient ?? "-") verified=\(i0.recipientVerified)") }
                        let denied = await n.sendTest(device: dev)
                        if case .failure(let e) = denied { report("e2e-no-alert-before-verification", e == .http(status: 409, code: "no_verified_recipient"), e.userMessage) } else { report("e2e-no-alert-before-verification", false, "sent to unverified address") }
                        let code = ((lastMail()?["textContent"] as? String) ?? "").components(separatedBy: " ").first(where: { $0.count == 7 && $0.hasSuffix(".") })?.dropLast() ?? ""
                        let wrong = await n.confirmRecipient(email: me, code: code == "000000" ? "111111" : "000000")
                        if case .failure = wrong { report("e2e-wrong-code-rejected", true, "") } else { report("e2e-wrong-code-rejected", false, "") }
                        let good = await n.confirmRecipient(email: me, code: String(code))
                        report("e2e-correct-code-verifies", { if case .success = good { return true } else { return false } }(), "code length \(code.count)")
                        if case .success(let i1) = await n.fetchBackendInfo() { report("e2e-info-verified", i1.recipientVerified && i1.recipient == "o***@gmail.com", "recipient=\(i1.recipient ?? "-")") }
                        let t = await n.sendTest(device: dev)
                        let to = ((lastMail()?["to"] as? [[String: Any]])?.first?["email"] as? String) ?? ""
                        report("e2e-alert-goes-to-verified-address", { if case .success = t { return true } else { return false } }() && to == me, "to=\(to)")
                        sem.signal(); return
                    }
                    if case .success(let i) = await n.fetchBackendInfo() { report("e2e-backend-info", true, "provider=\(i.provider) recipient=\(i.recipient ?? "none")") } else { report("e2e-backend-info", false, "failed") }
                    if case .success(let id) = await n.sendTest(device: dev) { report("e2e-test-email", true, "provider id \(id)") } else { report("e2e-test-email", false, "failed") }
                    var inc = Incident(batteryPercent: 77); inc.alarm = .succeeded; inc.screenLock = .requestedUnverified
                    inc.locationOutcome = .acquired
                    inc.location = LocationRecord(latitude: 12.9716, longitude: 77.5946, horizontalAccuracy: 12, acquiredAt: Date(), freshness: .fresh)
                    await n.submitInitial(inc, device: dev); await n.submitInitial(inc, device: dev)
                    let acc = (try? store.outbox(state: "accepted").count) ?? 0
                    report("e2e-incident-accepted-once", acc == 1, "accepted outbox items: \(acc)")
                } catch { report("e2e-enroll", false, "\(error)") }
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        }
        print(failures == 0 ? "SELF-CHECK OK" : "SELF-CHECK FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
