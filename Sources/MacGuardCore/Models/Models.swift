import Foundation

// MARK: - Power

public enum ExternalPower: String, Codable, Sendable {
    case connected, disconnected, unknown
}

public struct PowerSnapshot: Equatable, Codable, Sendable {
    public var external: ExternalPower
    public var batteryPercent: Int?
    public var isCharging: Bool?
    public var isFullyCharged: Bool?
    public var hasBattery: Bool
    public var timestamp: Date

    public init(external: ExternalPower, batteryPercent: Int? = nil, isCharging: Bool? = nil,
                isFullyCharged: Bool? = nil, hasBattery: Bool = true, timestamp: Date = Date()) {
        self.external = external
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isFullyCharged = isFullyCharged
        self.hasBattery = hasBattery
        self.timestamp = timestamp
    }

    /// Human-readable description; distinguishes charging / fully charged / battery / unknown.
    public var summary: String {
        switch external {
        case .unknown: return "Power state unavailable"
        case .disconnected: return "On battery power"
        case .connected:
            if isFullyCharged == true { return "Charger connected (fully charged)" }
            if isCharging == true { return "Charger connected (charging)" }
            return "Charger connected"
        }
    }
}

// MARK: - Location

public enum LocationFreshness: String, Codable, Sendable {
    case fresh, cached, lastKnown
}

public enum LocationAuthorization: String, Codable, Sendable {
    case notDetermined, denied, restricted, authorized, servicesDisabled
}

public enum LocationOutcome: String, Codable, Sendable {
    case acquired, timedOut, permissionDenied, disabledInSettings, invalidCoordinates, failed, cancelled
}

public struct LocationRecord: Equatable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double?
    /// When the position fix itself was produced.
    public var acquiredAt: Date
    public var source: String
    public var freshness: LocationFreshness

    public init?(latitude: Double, longitude: Double, horizontalAccuracy: Double?, acquiredAt: Date,
                 source: String = "CoreLocation", freshness: LocationFreshness) {
        guard LocationRecord.isValid(latitude: latitude, longitude: longitude) else { return nil }
        if let a = horizontalAccuracy, !(a >= 0 && a.isFinite) { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.acquiredAt = acquiredAt
        self.source = source
        self.freshness = freshness
    }

    public static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// Apple Maps link built only from validated numeric coordinates.
    public var mapURL: URL? {
        guard LocationRecord.isValid(latitude: latitude, longitude: longitude) else { return nil }
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "ll", value: String(format: "%.6f,%.6f", latitude, longitude)),
                         URLQueryItem(name: "q", value: "MacGuard last position")]
        return c?.url
    }
}

public struct LocationAcquisition: Equatable, Sendable {
    public var outcome: LocationOutcome
    public var record: LocationRecord?
    public var authorization: LocationAuthorization
    public init(outcome: LocationOutcome, record: LocationRecord?, authorization: LocationAuthorization) {
        self.outcome = outcome; self.record = record; self.authorization = authorization
    }
}

// MARK: - Incident

public enum IncidentKind: String, Codable, Sendable { case theft, test }

public enum ActionStatus: String, Codable, Sendable {
    case notStarted, inProgress, succeeded, failed, skipped
    /// Screen lock: command accepted but the session lock could not be verified.
    case requestedUnverified
}

public enum NotificationStatus: String, Codable, Sendable {
    case notStarted, disabled, queued, retrying, accepted, failed
}

public struct Incident: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var kind: IncidentKind
    public var createdAt: Date
    public var powerBefore: ExternalPower
    public var powerAfter: ExternalPower
    public var batteryPercent: Int?
    public var alarm: ActionStatus = .notStarted
    public var screenLock: ActionStatus = .notStarted
    public var locationOutcome: LocationOutcome?
    public var location: LocationRecord?
    public var notification: NotificationStatus = .notStarted
    public var followUpsSent: Int = 0
    public var chargerReconnectedAt: Date?

    public init(id: UUID = UUID(), kind: IncidentKind = .theft, createdAt: Date = Date(),
                powerBefore: ExternalPower = .connected, powerAfter: ExternalPower = .disconnected,
                batteryPercent: Int? = nil) {
        self.id = id; self.kind = kind; self.createdAt = createdAt
        self.powerBefore = powerBefore; self.powerAfter = powerAfter; self.batteryPercent = batteryPercent
    }
}

// MARK: - Security events

public enum SecurityEventType: String, Codable, Sendable, CaseIterable {
    case protectionArmed, protectionDisarmed, protectionRestored
    case chargerDisconnected, chargerReconnected
    case alarmStarted, alarmStopped, screenLockRequested
    case locationAcquired, locationFailed
    case emailQueued, emailAccepted, emailFailed
    case monitoringInterrupted, monitoringResumed, monitoringGap
    case testEvent

    public var title: String {
        switch self {
        case .protectionArmed: return "Protection armed"
        case .protectionDisarmed: return "Protection disarmed"
        case .protectionRestored: return "Protection restored after restart"
        case .chargerDisconnected: return "Charger disconnected"
        case .chargerReconnected: return "Charger reconnected"
        case .alarmStarted: return "Alarm started"
        case .alarmStopped: return "Alarm stopped"
        case .screenLockRequested: return "Screen-lock request issued"
        case .locationAcquired: return "Location acquired"
        case .locationFailed: return "Location acquisition failed"
        case .emailQueued: return "Email queued"
        case .emailAccepted: return "Email accepted by provider"
        case .emailFailed: return "Email delivery failure"
        case .monitoringInterrupted: return "Monitoring interrupted"
        case .monitoringResumed: return "Monitoring resumed"
        case .monitoringGap: return "Monitoring gap detected"
        case .testEvent: return "Test"
        }
    }
}

public struct SecurityEvent: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var type: SecurityEventType
    public var result: String
    public var incidentID: UUID?
    public var isTest: Bool

    public init(id: UUID = UUID(), timestamp: Date = Date(), type: SecurityEventType, result: String,
                incidentID: UUID? = nil, isTest: Bool = false) {
        self.id = id; self.timestamp = timestamp; self.type = type; self.result = result
        self.incidentID = incidentID; self.isTest = isTest
    }
}
