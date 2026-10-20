import Foundation

/// Runs the response to one confirmed theft incident: alarm and lock start immediately and never wait
/// for location or email; location and email run concurrently with bounded timeouts.
@MainActor
public final class TheftResponseCoordinator {
    public struct Hooks {
        public var transition: (GuardEvent) -> Void
        public var update: (Incident) -> Void
        public var log: (SecurityEventType, String, UUID?) -> Void
        public var monitoringState: () -> String
        public var localNotification: (String, String) -> Void
        public init(transition: @escaping (GuardEvent) -> Void, update: @escaping (Incident) -> Void,
                    log: @escaping (SecurityEventType, String, UUID?) -> Void, monitoringState: @escaping () -> String,
                    localNotification: @escaping (String, String) -> Void) {
            self.transition = transition; self.update = update; self.log = log
            self.monitoringState = monitoringState; self.localNotification = localNotification
        }
    }

    private let alarm: AlarmControlling
    private let locker: ScreenLocking
    private let location: LocationResolving
    private let notifier: IncidentNotifying?
    private let store: SecurityEventStore?
    private let device: DeviceInfo
    private var handled = Set<UUID>()
    private var followUpTask: Task<Void, Never>?
    private var responseTask: Task<Void, Never>?

    public init(alarm: AlarmControlling, locker: ScreenLocking, location: LocationResolving,
                notifier: IncidentNotifying?, store: SecurityEventStore?, device: DeviceInfo) {
        self.alarm = alarm; self.locker = locker; self.location = location
        self.notifier = notifier; self.store = store; self.device = device
    }

    /// Runs the whole response. Duplicate invocations for the same incident are ignored.
    public func respond(to initial: Incident, settings: AppSettings, hooks: Hooks) async {
        guard handled.insert(initial.id).inserted else { return }
        var incident = initial
        let id = incident.id
        func commit() { try? store?.save(incident); hooks.update(incident) }
        commit()
        hooks.log(.chargerDisconnected, "Unauthorized disconnection confirmed", id)

        // 1. Alarm — synchronous start, independent of every other subsystem.
        let alarmOK = alarm.start(settings: settings.alarm)
        incident.alarm = alarmOK ? .succeeded : .failed
        hooks.transition(.alarmStarted)
        hooks.log(.alarmStarted, alarmOK ? "Alarm playing" : "Alarm sound could not be started", id)
        if settings.alarm.showLocalNotification {
            hooks.localNotification("MacGuard alarm", "Charger disconnected while protection was armed.")
        }
        commit()

        // 2. Screen lock — concurrent.
        let lockTask: Task<ActionStatus, Never>? = settings.autoScreenLock ? Task { [locker] in await locker.lock() } : nil
        if lockTask == nil { incident.screenLock = .skipped } else { incident.screenLock = .inProgress }

        // 3. Location — concurrent, with timeout.
        hooks.transition(.locationStarted)
        let locTask = Task { @MainActor [location] in
            await location.acquire(enabled: settings.locationEnabled, accuracy: settings.locationAccuracy,
                                   timeout: settings.locationTimeout, allowLastKnown: settings.keepLastKnownLocation)
        }
        commit()

        let emailOn = settings.emailEnabled && notifier != nil
        let waitForLocationFirst = settings.followUpMode == .initialOnly

        // 4. Initial alert with what is known now (unless a single combined email was requested).
        if emailOn && !waitForLocationFirst {
            incident.notification = .queued
            hooks.log(.emailQueued, "Initial alert queued", id)
            commit()
            await notifier?.submitInitial(incident, device: device)
        }

        let acq = await locTask.value
        incident.locationOutcome = acq.outcome
        incident.location = acq.record
        if let r = acq.record, acq.outcome == .acquired {
            hooks.log(.locationAcquired, "\(r.freshness.rawValue), ±\(Int(r.horizontalAccuracy ?? -1)) m", id)
        } else if let r = acq.record {
            hooks.log(.locationFailed, "\(acq.outcome.rawValue); using \(r.freshness.rawValue) position", id)
        } else {
            hooks.log(.locationFailed, acq.outcome.rawValue, id)
        }
        hooks.transition(.locationFinished)
        if let lockTask {
            incident.screenLock = await lockTask.value
            hooks.log(.screenLockRequested, "Result: \(incident.screenLock.rawValue)", id)
        }
        commit()

        if emailOn {
            if waitForLocationFirst {
                incident.notification = .queued
                hooks.log(.emailQueued, "Alert queued", id)
                commit()
                await notifier?.submitInitial(incident, device: device)
            } else {
                await notifier?.submitLocation(incident, sequence: 1, monitoring: hooks.monitoringState(), followUp: false)
            }
            startFollowUps(incident: incident, settings: settings, hooks: hooks)
        } else {
            incident.notification = .disabled
            commit()
            hooks.transition(.notificationSent) // nothing further to wait for
        }
    }

    /// Called when delivery status for an incident changes.
    public func notificationStatusChanged(_ incident: inout Incident, status: NotificationStatus, hooks: Hooks) {
        incident.notification = status
        if status == .accepted { hooks.transition(.notificationSent) }
    }

    private func startFollowUps(incident: Incident, settings: AppSettings, hooks: Hooks) {
        guard settings.followUpMode == .periodic else { return }
        followUpTask?.cancel()
        let started = Date()
        var last = incident.location?.acquiredAt
        var seq = 1
        followUpTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, Date().timeIntervalSince(started) < settings.followUpMaxDuration {
                try? await Task.sleep(nanoseconds: UInt64(max(60, settings.followUpInterval) * 1e9))
                guard !Task.isCancelled, let self else { return }
                let acq = await self.location.acquire(enabled: settings.locationEnabled, accuracy: settings.locationAccuracy,
                                                      timeout: settings.locationTimeout, allowLastKnown: false)
                // Skip stale or unchanged positions rather than repeating old coordinates.
                guard let rec = acq.record, rec.freshness == .fresh, rec.acquiredAt != last else { continue }
                last = rec.acquiredAt; seq += 1
                var inc = incident; inc.location = rec; inc.locationOutcome = acq.outcome
                await self.notifier?.submitLocation(inc, sequence: seq, monitoring: hooks.monitoringState(), followUp: true)
            }
        }
    }

    public func cancelFollowUps() { followUpTask?.cancel(); followUpTask = nil }
    public func forget(_ id: UUID) { handled.remove(id) }
}
