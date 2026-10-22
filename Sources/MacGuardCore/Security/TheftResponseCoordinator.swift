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
    private let sleep: @Sendable (TimeInterval) async -> Void
    private var sequence = 1   // number of the last location email for the current incident (1 = the combined alert)

    public init(alarm: AlarmControlling, locker: ScreenLocking, location: LocationResolving,
                notifier: IncidentNotifying?, store: SecurityEventStore?, device: DeviceInfo,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) }) {
        self.sleep = sleep
        self.alarm = alarm; self.locker = locker; self.location = location
        self.notifier = notifier; self.store = store; self.device = device
    }

    /// Runs the whole response. Duplicate invocations for the same incident are ignored.
    public func respond(to initial: Incident, settings: AppSettings, hooks: Hooks) async {
        guard handled.insert(initial.id).inserted else { return }
        cancelFollowUps() // a new incident replaces the previous incident's follow-up schedule
        sequence = 1
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
            // ONE email: the theft alert together with the location (or an honest "location unavailable"). The alarm and the screen
            // lock never wait for this; only the email does, for at most the location timeout.
            incident.notification = .queued
            hooks.log(.emailQueued, "Alert queued", id)
            commit()
            await notifier?.submitInitial(incident, device: device)
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

    /// "Repeat while unplugged": one email every `followUpInterval`, counted from the moment of the disconnect, for as long as this
    /// incident is running. Reconnecting the charger (cancelFollowUps) stops it; unplugging again is a new incident with a fresh timer.
    /// Each email carries the best position available and says honestly whether it is fresh, cached or last known.
    private func startFollowUps(incident: Incident, settings: AppSettings, hooks: Hooks, origin: Date? = nil) {
        guard settings.followUpMode == .periodic else { return }
        followUpTask?.cancel()
        let interval = max(60, settings.followUpInterval)
        let origin = origin ?? incident.createdAt
        followUpTask = Task { @MainActor [weak self] in
            var n = 1
            while !Task.isCancelled, Double(n) * interval <= settings.followUpMaxDuration {
                let wait = origin.addingTimeInterval(Double(n) * interval).timeIntervalSinceNow
                if let self { await self.sleep(wait) }
                guard !Task.isCancelled, let self else { return }
                let acq = await self.location.acquire(enabled: settings.locationEnabled, accuracy: settings.locationAccuracy,
                                                      timeout: settings.locationTimeout, allowLastKnown: settings.keepLastKnownLocation)
                guard !Task.isCancelled else { return }
                sequence += 1; n += 1
                var inc = incident; inc.location = acq.record; inc.locationOutcome = acq.outcome
                await self.notifier?.submitLocation(inc, sequence: self.sequence, monitoring: hooks.monitoringState(), followUp: true)
            }
        }
    }

    /// The owner said "No, keep tracking" after the charger was reconnected (a thief can plug it in): restart the repeat timer from now.
    public func resumeFollowUps(incident: Incident, settings: AppSettings, hooks: Hooks) {
        guard settings.emailEnabled, notifier != nil else { return }
        startFollowUps(incident: incident, settings: settings, hooks: hooks, origin: Date())
    }

    /// The Mac just got internet again while an incident is running: take a fresh position and email it, so the owner sees where it is
    /// now rather than where it was when the connection dropped. Queued older location updates are replaced by this one.
    public func networkReturned(incident: Incident, settings: AppSettings, hooks: Hooks) async {
        guard settings.emailEnabled, let notifier else { return }
        let acq = await location.acquire(enabled: settings.locationEnabled, accuracy: settings.locationAccuracy,
                                         timeout: settings.locationTimeout, allowLastKnown: settings.keepLastKnownLocation)
        sequence += 1
        var inc = incident; inc.location = acq.record; inc.locationOutcome = acq.outcome
        hooks.log(.emailQueued, "Back online: location update queued", incident.id)
        await notifier.submitLocation(inc, sequence: sequence, monitoring: hooks.monitoringState(), followUp: true)
    }

    public func cancelFollowUps() { followUpTask?.cancel(); followUpTask = nil }
    public func forget(_ id: UUID) { handled.remove(id) }
}
