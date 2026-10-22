import Foundation

public struct AlarmSettings: Codable, Equatable, Sendable {
    public var sound = "Sosumi"
    public var repeatInterval: TimeInterval = 2
    public var initialDelay: TimeInterval = 0
    public var showLocalNotification = true
    public var maximizeVolume = true
    public init() {}
}

public enum FollowUpMode: String, Codable, CaseIterable, Sendable {
    case initialOnly, oneFollowUp, periodic
    public var title: String {
        switch self {
        case .initialOnly: return "Initial alert only"
        case .oneFollowUp: return "Initial alert plus one follow-up"
        case .periodic: return "Repeat while the charger is unplugged"
        }
    }
}

public enum LocationAccuracySetting: String, Codable, CaseIterable, Sendable {
    case best, tenMeters, hundredMeters
    public var title: String {
        switch self { case .best: return "Best available"; case .tenMeters: return "Within ~10 m"; case .hundredMeters: return "Within ~100 m" }
    }
    public var meters: Double { switch self { case .best: return 5; case .tenMeters: return 10; case .hundredMeters: return 100 } }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var alarm = AlarmSettings()
    /// 0 = immediate; otherwise seconds of confirmation before a disconnect is treated as theft.
    public var disconnectDelay: TimeInterval = 1
    public var autoScreenLock = true
    public var emailEnabled = false
    /// Sender shown on alert emails; must be a sender verified in the Brevo account.
    public var senderEmail = ""
    /// Verified address that receives alerts (set only after the emailed code is confirmed).
    public var recipientEmail = ""
    public var followUpMode: FollowUpMode = .oneFollowUp
    public var followUpInterval: TimeInterval = 600
    public var followUpMaxDuration: TimeInterval = 6 * 3600
    public var sendRecoveryNotice = false
    public var locationEnabled = true
    public var locationAccuracy: LocationAccuracySetting = .tenMeters
    public var locationTimeout: TimeInterval = 20
    public var keepLastKnownLocation = true
    public var locationRetentionDays = 7
    public var eventRetentionDays = 90
    public var launchAtLogin = false
    public var resumeArmedOnLaunch = true
    public var onboardingCompleted = false
    /// Silence the alarm when the charger is plugged back in. Protection stays armed until the owner disarms.
    public var stopAlarmOnReconnect = true
    public init() {}

    /// Tolerant decoding: settings saved by an older version keep their values and new fields get defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        alarm = try c.decodeIfPresent(type(of: d.alarm).self, forKey: .alarm) ?? d.alarm
        disconnectDelay = try c.decodeIfPresent(type(of: d.disconnectDelay).self, forKey: .disconnectDelay) ?? d.disconnectDelay
        autoScreenLock = try c.decodeIfPresent(type(of: d.autoScreenLock).self, forKey: .autoScreenLock) ?? d.autoScreenLock
        emailEnabled = try c.decodeIfPresent(type(of: d.emailEnabled).self, forKey: .emailEnabled) ?? d.emailEnabled
        senderEmail = try c.decodeIfPresent(type(of: d.senderEmail).self, forKey: .senderEmail) ?? d.senderEmail
        recipientEmail = try c.decodeIfPresent(type(of: d.recipientEmail).self, forKey: .recipientEmail) ?? d.recipientEmail
        followUpMode = try c.decodeIfPresent(type(of: d.followUpMode).self, forKey: .followUpMode) ?? d.followUpMode
        followUpInterval = try c.decodeIfPresent(type(of: d.followUpInterval).self, forKey: .followUpInterval) ?? d.followUpInterval
        followUpMaxDuration = try c.decodeIfPresent(type(of: d.followUpMaxDuration).self, forKey: .followUpMaxDuration) ?? d.followUpMaxDuration
        sendRecoveryNotice = try c.decodeIfPresent(type(of: d.sendRecoveryNotice).self, forKey: .sendRecoveryNotice) ?? d.sendRecoveryNotice
        locationEnabled = try c.decodeIfPresent(type(of: d.locationEnabled).self, forKey: .locationEnabled) ?? d.locationEnabled
        locationAccuracy = try c.decodeIfPresent(type(of: d.locationAccuracy).self, forKey: .locationAccuracy) ?? d.locationAccuracy
        locationTimeout = try c.decodeIfPresent(type(of: d.locationTimeout).self, forKey: .locationTimeout) ?? d.locationTimeout
        keepLastKnownLocation = try c.decodeIfPresent(type(of: d.keepLastKnownLocation).self, forKey: .keepLastKnownLocation) ?? d.keepLastKnownLocation
        locationRetentionDays = try c.decodeIfPresent(type(of: d.locationRetentionDays).self, forKey: .locationRetentionDays) ?? d.locationRetentionDays
        eventRetentionDays = try c.decodeIfPresent(type(of: d.eventRetentionDays).self, forKey: .eventRetentionDays) ?? d.eventRetentionDays
        launchAtLogin = try c.decodeIfPresent(type(of: d.launchAtLogin).self, forKey: .launchAtLogin) ?? d.launchAtLogin
        resumeArmedOnLaunch = try c.decodeIfPresent(type(of: d.resumeArmedOnLaunch).self, forKey: .resumeArmedOnLaunch) ?? d.resumeArmedOnLaunch
        onboardingCompleted = try c.decodeIfPresent(type(of: d.onboardingCompleted).self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
        stopAlarmOnReconnect = try c.decodeIfPresent(type(of: d.stopAlarmOnReconnect).self, forKey: .stopAlarmOnReconnect) ?? d.stopAlarmOnReconnect
        // 0.2.0 had a single "wait between emails" value; it meant "repeat at this interval", so keep that intent.
        if let legacy = (try? Legacy(from: decoder))?.emailMinInterval, legacy >= 60 { followUpMode = .periodic; followUpInterval = legacy }
    }
    private struct Legacy: Decodable { var emailMinInterval: TimeInterval? }
    private static let defaults = AppSettings()
}

@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings { didSet { save() } }
    private let defaults: UserDefaults
    private let key = "macguard.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let d = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: d) {
            settings = s
        } else { settings = AppSettings() }
    }
    private func save() {
        if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: key) }
    }
}
