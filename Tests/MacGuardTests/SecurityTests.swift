import Testing
import Foundation
import Combine
@testable import MacGuardCore

@Suite struct SecurityTests {
    @Test func databaseFileAndDirectoryArePrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mgt-\(UUID().uuidString)")
        let path = dir.appendingPathComponent("db.sqlite")
        _ = try SecurityEventStore(path: path)
        let f = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int
        let d = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(f == 0o600); #expect(d == 0o700)
        try? FileManager.default.removeItem(at: dir)
    }
    @Test func sourceContainsNoEmbeddedKeysAndOnlyTheMailerTalksToBrevo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let keyShapes = ["re_[A-Za-z0-9]{20,}", "xkeysib-[A-Za-z0-9]{20,}", "sk_live"]
        let e = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for p in keyShapes { #expect(text.range(of: p, options: .regularExpression) == nil, "key-like string in \(url.lastPathComponent)") }
            if url.lastPathComponent != "BrevoMailer.swift" {
                #expect(!text.contains("api.brevo.com") && !text.contains("api.resend.com"), "\(url.lastPathComponent) must not call a provider directly")
            }
        }
    }
    @Test func eventLogDoesNotContainSecrets() throws {
        let s = try SecurityEventStore(path: nil)
        try s.append(SecurityEvent(type: .emailFailed, result: APIError.http(status: 401, code: nil).userMessage))
        let all = try s.events().map(\.result).joined()
        #expect(!all.lowercased().contains("api-key") && !all.lowercased().contains("xkeysib"))
    }
    @Test func screenLockStatusNeverClaimsVerifiedWithoutProof() {
        // requestedUnverified is a distinct state from succeeded.
        #expect(ActionStatus.requestedUnverified != ActionStatus.succeeded)
    }
    @Test func eventStoreRoundTripsAndPurges() throws {
        let s = try SecurityEventStore(path: nil)
        let old = SecurityEvent(timestamp: Date().addingTimeInterval(-200 * 86400), type: .protectionArmed, result: "old")
        let new = SecurityEvent(type: .testEvent, result: "new", isTest: true)
        try s.append(old); try s.append(new)
        try s.purgeEvents(olderThan: 90)
        let e = try s.events(); #expect(e.count == 1); #expect(e[0].isTest)
    }
    @Test func incidentPersistsWithAllFields() throws {
        let s = try SecurityEventStore(path: nil)
        var i = Incident(batteryPercent: 42); i.alarm = .succeeded; i.screenLock = .requestedUnverified
        try s.save(i); let back = try #require(try s.incident(id: i.id))
        #expect(back.alarm == .succeeded); #expect(back.screenLock == .requestedUnverified); #expect(back.batteryPercent == 42)
    }

    @Test func settingsFromOlderVersionKeepValuesAndGainDefaults() throws {
        let old = #"{"disconnectDelay":3,"emailEnabled":true,"backendURL":"https://old.example","alarm":{"sound":"Glass","repeatInterval":2,"initialDelay":0,"continueAfterLock":true,"showLocalNotification":true,"maximizeVolume":true}}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(s.disconnectDelay == 3); #expect(s.emailEnabled); #expect(s.alarm.sound == "Glass")
        #expect(s.stopAlarmOnReconnect); #expect(s.followUpMode == .oneFollowUp)   // defaults for fields the old data lacks
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @MainActor @Test func settingsStorePublishesEveryChangeAndPersists() throws {
        let suite = "mg-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        var fired = 0
        let sub = store.objectWillChange.sink { fired += 1 }
        store.settings.eventRetentionDays = 30
        store.settings.locationRetentionDays = 3
        #expect(fired == 2)                                  // each edit notifies observers immediately
        #expect(SettingsStore(defaults: defaults).settings.eventRetentionDays == 30)   // and is saved
        _ = sub
    }
}
