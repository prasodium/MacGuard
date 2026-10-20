import Foundation

public struct DeviceInfo: Codable, Equatable, Sendable {
    public var name: String, model: String?, osVersion: String
    public init(name: String, model: String?, osVersion: String) { self.name = name; self.model = model; self.osVersion = osVersion }
    public static func current() -> DeviceInfo {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceInfo(name: Host.current().localizedName ?? "Mac", model: size > 0 ? String(cString: buf) : nil,
                          osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }
}

public struct LocationPayload: Codable, Equatable, Sendable {
    public var latitude: Double, longitude: Double
    public var accuracy: Double?
    public var acquiredAt: Date
    public var source: String
    public var freshness: String
    public init(_ r: LocationRecord) {
        latitude = r.latitude; longitude = r.longitude; accuracy = r.horizontalAccuracy
        acquiredAt = r.acquiredAt; source = r.source; freshness = r.freshness.rawValue
    }
}

public struct IncidentPayload: Codable, Equatable, Sendable {
    public var incidentId: String
    public var eventType: String
    public var occurredAt: Date
    public var timeZone: String
    public var device: DeviceInfo
    public var powerBefore: String, powerAfter: String
    public var batteryPercent: Int?
    public var alarmStatus: String, screenLockStatus: String
    public var locationStatus: String
    public var location: LocationPayload?
    public var isTest: Bool
}

public struct LocationUpdatePayload: Codable, Equatable, Sendable {
    public var incidentId: String
    public var sequence: Int
    public var location: LocationPayload?
    public var locationStatus: String
    public var monitoringState: String
    public var isFollowUp: Bool
    public var sentAt: Date
}

public struct StatusPayload: Codable, Equatable, Sendable {
    public var incidentId: String
    public var statusCode: String   // charger_reconnected | alarm_silenced | protection_disarmed
    public var monitoringState: String
    public var timestamp: Date
}

public protocol IncidentNotifying: Sendable {
    func submitInitial(_ incident: Incident, device: DeviceInfo) async
    func submitLocation(_ incident: Incident, sequence: Int, monitoring: String, followUp: Bool) async
    func submitStatus(incidentID: UUID, code: String, monitoring: String) async
    func sendTest(device: DeviceInfo) async -> Result<String, APIError>
    func flush() async
}

/// Queues alerts in the local outbox and delivers them with bounded exponential backoff.
/// "accepted" means the backend accepted the provider request; inbox delivery is NOT confirmed.
public actor TheftNotificationService: IncidentNotifying {
    private let api: AlertAPI
    private let store: SecurityEventStore
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let retryDelays: [TimeInterval]
    private let maxAttemptsPerFlush: Int
    private var flushing = false
    public var onStatus: (@Sendable (UUID, NotificationStatus, String) -> Void)?

    public init(api: AlertAPI, store: SecurityEventStore,
                retryDelays: [TimeInterval] = [2, 4, 8, 16, 32],
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.api = api; self.store = store; self.retryDelays = retryDelays; self.sleeper = sleeper
        self.maxAttemptsPerFlush = retryDelays.count + 1
    }

    public func setOnStatus(_ f: (@Sendable (UUID, NotificationStatus, String) -> Void)?) { onStatus = f }

    static func payload(for incident: Incident, device: DeviceInfo) -> IncidentPayload {
        IncidentPayload(incidentId: incident.id.uuidString.lowercased(), eventType: incident.kind == .test ? "test" : "charger_disconnected",
                        occurredAt: incident.createdAt, timeZone: TimeZone.current.identifier, device: device,
                        powerBefore: incident.powerBefore.rawValue, powerAfter: incident.powerAfter.rawValue,
                        batteryPercent: incident.batteryPercent, alarmStatus: incident.alarm.rawValue,
                        screenLockStatus: incident.screenLock.rawValue,
                        locationStatus: incident.locationOutcome?.rawValue ?? "pending",
                        location: incident.location.map(LocationPayload.init), isTest: incident.kind == .test)
    }

    private func enqueue<T: Encodable>(id: String, incident: UUID, kind: String, _ body: T) {
        guard let data = try? JSONEncoder.iso.encode(body) else { return }
        try? store.enqueue(OutboxItem(id: id, incidentID: incident, kind: kind, payload: data, attempts: 0,
                                      nextAttempt: Date(), state: "pending", lastError: nil))
    }

    public func submitInitial(_ incident: Incident, device: DeviceInfo) async {
        enqueue(id: "\(incident.id.uuidString.lowercased()):initial", incident: incident.id, kind: "initial",
                Self.payload(for: incident, device: device))
        onStatus?(incident.id, .queued, "Alert queued")
        await flush()
    }

    public func submitLocation(_ incident: Incident, sequence: Int, monitoring: String, followUp: Bool) async {
        let p = LocationUpdatePayload(incidentId: incident.id.uuidString.lowercased(), sequence: sequence,
                                      location: incident.location.map(LocationPayload.init),
                                      locationStatus: incident.locationOutcome?.rawValue ?? "unknown",
                                      monitoringState: monitoring, isFollowUp: followUp, sentAt: Date())
        enqueue(id: "\(p.incidentId):location:\(sequence)", incident: incident.id, kind: "location", p)
        await flush()
    }

    public func submitStatus(incidentID: UUID, code: String, monitoring: String) async {
        let p = StatusPayload(incidentId: incidentID.uuidString.lowercased(), statusCode: code, monitoringState: monitoring, timestamp: Date())
        enqueue(id: "\(p.incidentId):status:\(code)", incident: incidentID, kind: "status", p)
        await flush()
    }

    public func sendTest(device: DeviceInfo) async -> Result<String, APIError> {
        let inc = Incident(kind: .test, batteryPercent: nil)
        let body = (try? JSONEncoder.iso.encode(Self.payload(for: inc, device: device))) ?? Data()
        do {
            let r = try await api.post(path: "/v1/test-email", body: body)
            return .success((r.json?["providerId"] as? String) ?? "accepted")
        } catch let e as APIError { return .failure(e) } catch { return .failure(.network) }
    }

    private func path(for item: OutboxItem) -> String {
        let id = item.incidentID.uuidString.lowercased()
        switch item.kind {
        case "location": return "/v1/incidents/\(id)/location"
        case "status": return "/v1/incidents/\(id)/status"
        default: return "/v1/incidents"
        }
    }

    /// Delivers all due items. Safe to call repeatedly (e.g. when connectivity returns); never runs concurrently.
    public func flush() async {
        guard !flushing else { return }
        flushing = true; defer { flushing = false }
        guard let items = try? store.outbox(state: "pending") else { return }
        for item in items where item.nextAttempt <= Date() {
            var attempts = item.attempts
            var sessionAttempts = 0
            while true {
                attempts += 1; sessionAttempts += 1
                do {
                    let r = try await api.post(path: path(for: item), body: item.payload)
                    try? store.updateOutbox(id: item.id, state: "accepted", attempts: attempts, next: Date(), error: nil)
                    onStatus?(item.incidentID, .accepted, (r.json?["status"] as? String) ?? "accepted")
                    break
                } catch let e as APIError {
                    if e.isRetryable && sessionAttempts < maxAttemptsPerFlush {
                        onStatus?(item.incidentID, .retrying, e.userMessage)
                        await sleeper(retryDelays[min(sessionAttempts - 1, retryDelays.count - 1)])
                        continue
                    }
                    // Retryable but exhausted: stays pending for the next connectivity event/flush; permanent: failed.
                    let permanent = !e.isRetryable
                    try? store.updateOutbox(id: item.id, state: permanent ? "failed" : "pending", attempts: attempts,
                                            next: Date().addingTimeInterval(permanent ? 0 : 60), error: e.userMessage)
                    onStatus?(item.incidentID, permanent ? .failed : .queued, e.userMessage)
                    break
                } catch {
                    try? store.updateOutbox(id: item.id, state: "failed", attempts: attempts, next: Date(), error: "Unexpected error")
                    onStatus?(item.incidentID, .failed, "Unexpected error")
                    break
                }
            }
        }
    }
}
