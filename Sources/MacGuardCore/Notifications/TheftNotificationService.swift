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

/// Queues alerts in the local outbox and sends them straight to Brevo with bounded exponential backoff.
/// "accepted" means Brevo accepted the message; inbox delivery is NOT confirmed.
public actor TheftNotificationService: IncidentNotifying {
    private let mailer: MailSending
    private let store: SecurityEventStore
    private let recipient: @Sendable () -> String?
    private let sleeper: @Sendable (TimeInterval) async -> Void
    private let retryDelays: [TimeInterval]
    private let maxAttemptsPerFlush: Int
    private var flushing = false
    public var onStatus: (@Sendable (UUID, NotificationStatus, String) -> Void)?

    public init(mailer: MailSending, store: SecurityEventStore, recipient: @escaping @Sendable () -> String?,
                retryDelays: [TimeInterval] = [2, 4, 8, 16, 32],
                sleeper: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.mailer = mailer; self.store = store; self.recipient = recipient
        self.retryDelays = retryDelays; self.sleeper = sleeper
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
        // INSERT OR IGNORE on the id: the same incident/sequence is never queued (or emailed) twice.
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

    /// Sends one test message to the verified address. Not queued, not a theft incident.
    public func sendTest(device: DeviceInfo) async -> Result<String, APIError> {
        guard let to = recipient() else { return .failure(.noRecipient) }
        let r = EmailTemplates.incident(Self.payload(for: Incident(kind: .test), device: device))
        do { return .success(try await mailer.send(OutgoingMail(to: to, subject: r.subject, html: r.html, text: r.text))) }
        catch let e as APIError { return .failure(e) } catch { return .failure(.network) }
    }

    private func render(_ item: OutboxItem) throws -> EmailTemplates.Rendered {
        let d = JSONDecoder.iso
        switch item.kind {
        case "location": return EmailTemplates.location(try d.decode(LocationUpdatePayload.self, from: item.payload))
        case "status": return EmailTemplates.status(try d.decode(StatusPayload.self, from: item.payload))
        default: return EmailTemplates.incident(try d.decode(IncidentPayload.self, from: item.payload))
        }
    }

    private static func sequence(_ id: String) -> Int { Int(id.split(separator: ":").last ?? "") ?? 0 }

    /// Delivers all due items. Safe to call repeatedly (e.g. when connectivity returns); never runs concurrently.
    public func flush() async {
        guard !flushing else { return }
        flushing = true; defer { flushing = false }
        guard let items = try? store.outbox(state: "pending") else { return }
        for item in items where item.nextAttempt <= Date() {
            // Several location updates queued while offline: only the newest one is worth sending once the Mac is back online.
            if item.kind == "location", items.contains(where: { $0.kind == "location" && $0.incidentID == item.incidentID && Self.sequence($0.id) > Self.sequence(item.id) }) {
                try? store.updateOutbox(id: item.id, state: "superseded", attempts: item.attempts, next: Date(), error: "Replaced by a newer location update")
                continue
            }
            guard let mail = try? render(item) else {
                try? store.updateOutbox(id: item.id, state: "failed", attempts: item.attempts, next: Date(), error: "Unreadable queued alert")
                continue
            }
            guard let to = recipient() else {   // keep the alert; it is sent as soon as an address is verified
                try? store.updateOutbox(id: item.id, state: "pending", attempts: item.attempts, next: Date().addingTimeInterval(60), error: APIError.noRecipient.userMessage)
                onStatus?(item.incidentID, .failed, APIError.noRecipient.userMessage)
                continue
            }
            var attempts = item.attempts, sessionAttempts = 0
            while true {
                attempts += 1; sessionAttempts += 1
                do {
                    _ = try await mailer.send(OutgoingMail(to: to, subject: mail.subject, html: mail.html, text: mail.text))
                    try? store.updateOutbox(id: item.id, state: "accepted", attempts: attempts, next: Date(), error: nil)
                    onStatus?(item.incidentID, .accepted, "Accepted by Brevo")
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
