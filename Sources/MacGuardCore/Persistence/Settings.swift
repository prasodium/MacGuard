import Foundation

public struct AlarmSettings: Codable, Equatable, Sendable {
    public var sound = "Sosumi"
    public var repeatInterval: TimeInterval = 2
    public var initialDelay: TimeInterval = 0
    public var continueAfterLock = true
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
        case .periodic: return "Periodic updates while online"
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
    public var backendURL = ""
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
    public init() {}
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
