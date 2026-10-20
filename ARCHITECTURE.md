# Architecture

**Layout** — `Sources/MacGuardCore` (library, no UI; fully unit-tested) · `Sources/MacGuard` (SwiftUI app, `AppCoordinator`, `--self-check`) · `backend/` (Node, zero dependencies).

## Why this split
Security logic is UI-free and dependency-injected (protocols: `PowerSourceReading`, `SoundPlaying`, `AlarmControlling`, `ScreenLocking`, `LocationProviding/Resolving`, `AlertAPI`, `HTTPTransport`, `IncidentNotifying`, `SecretStoring`, `OwnerAuthenticating`) so each subsystem fails independently and is mockable.

## Power monitoring
`IOKitPowerReader` reads `IOPSGetProvidingPowerSourceType` (AC / Battery / UPS) plus battery details. `IOKitPowerNotifier` subscribes via `IOPSNotificationCreateRunLoopSource` (event-driven); a 15 s tolerance-based timer reconciles missed notifications; wake from sleep forces a refresh. `PowerTransitionDetector` is a pure struct: first valid read = baseline (never an event if on battery); disconnect→ pending (delay) → confirmed only if still disconnected when re-read at the deadline; duplicates produce nothing; read failures and `unknown` never produce a disconnect. `PowerMonitor` maps repeated failures to `MonitoringHealth.degraded`.

## State machine (`GuardStateMachine`)
Phases: disarmed, preparingToArm, armed, powerTransitionPending, theftDetected, alarmActive, locationPending, notificationPending, notificationSent, recoveryPending, monitoringDegraded. The theft flow is **forward-only** with ranks, so async completions arriving out of order (e.g. email accepted before location finished) cannot regress state. A second `theftConfirmed` is rejected (duplicate suppression). Unauthorized disarm during an incident is rejected. Charger reconnection only sets a flag / moves to `recoveryPending` — it never disarms, silences, or unlocks.

## Incident response
`TheftResponseCoordinator.respond` (once per incident id): persist → start alarm synchronously → launch lock (private SACLockScreenImmediate, fallback display sleep, verified via CGSession) and location tasks concurrently → submit initial alert immediately (unless "initial only" mode, which waits for location up to the timeout) → location update → optional periodic follow-ups (fresh & changed positions only). Alarm/lock never await email or location.

## Notifications
Alerts are written to a SQLite outbox keyed `"<incident>:initial|location:N|status:code"` (also the backend idempotency key). `flush()` retries 5xx/429/network with delays 2,4,8,16,32 s per flush; exhausted items stay pending and are retried when `NWPathMonitor` reports connectivity. 4xx (auth/validation) is permanent.

## Backend
`POST /v1/enroll` (single-use hashed token → installation + secret), `POST /v1/incidents`, `/v1/incidents/{id}/location`, `/v1/incidents/{id}/status`, `/v1/test-email`, `GET /healthz`. Recipient is **server-side only**. Email provider is behind `send()`; Resend implemented (`Idempotency-Key` header); `console` provider for development.

## Background model
A regular app with `MenuBarExtra`; `applicationShouldTerminateAfterLastWindowClosed = false`; quitting while protected requires owner auth. Optional `SMAppService.mainApp` login item. A 30 s heartbeat in SQLite lets the next launch record a monitoring gap and (if enabled) resume protection only when the charger is connected.
