# Architecture

**Layout** — `Sources/MacGuardCore` (library, no UI; fully unit-tested) · `Sources/MacGuard` (SwiftUI app, `AppCoordinator`, `--self-check`). No server: the app talks to Brevo directly.

## Why this split
Security logic is UI-free and dependency-injected (protocols: `PowerSourceReading`, `SoundPlaying`, `AlarmControlling`, `ScreenLocking`, `LocationProviding/Resolving`, `MailSending`, `HTTPTransport`, `IncidentNotifying`, `SecretStoring`, `OwnerAuthenticating`) so each subsystem fails independently and is mockable.

## Power monitoring
`IOKitPowerReader` reads `IOPSGetProvidingPowerSourceType` (AC / Battery / UPS) plus battery details. `IOKitPowerNotifier` subscribes via `IOPSNotificationCreateRunLoopSource` (event-driven); a 15 s tolerance-based timer reconciles missed notifications; wake from sleep forces a refresh. `PowerTransitionDetector` is a pure struct: first valid read = baseline (never an event if on battery); disconnect → pending (delay) → confirmed only if still disconnected when re-read at the deadline; duplicates produce nothing; read failures and `unknown` never produce a disconnect. `PowerMonitor` maps repeated failures to `MonitoringHealth.degraded`.

## State machine (`GuardStateMachine`)
Phases: disarmed, preparingToArm, armed, powerTransitionPending, theftDetected, alarmActive, locationPending, notificationPending, notificationSent, recoveryPending, monitoringDegraded. The theft flow is **forward-only** with ranks, so out-of-order async completions cannot regress state. A second `theftConfirmed` is rejected as a duplicate **unless the charger was reconnected in between**, in which case it starts a new incident (so every unplug alarms). Unauthorized disarm during an incident is rejected. Reconnection never disarms or unlocks; by default (setting) it silences the alarm.

## Incident response
`TheftResponseCoordinator.respond` (once per incident id): persist → start alarm synchronously → launch screen lock (private `SACLockScreenImmediate`, fallback display sleep, verified via CGSession) and location tasks concurrently → submit the initial alert immediately (unless "initial only" mode, which waits for location up to the timeout) → location update → optional periodic follow-ups (fresh, changed positions only). Alarm/lock never await email or location.

## Email (direct to Brevo)
- `BrevoMailer` (`MailSending`): `POST https://api.brevo.com/v3/smtp/email` with the `api-key` header; key read from the Keychain; `GET /v3/account` verifies a key without sending. HTTPS only.
- `EmailTemplates`: pure functions that render the HTML + plain-text alerts (alert, location/follow-up, status, verification code, recipient-changed notice).
- `TheftNotificationService`: SQLite outbox keyed `"<incident>:initial|location:N|status:code"` (`INSERT OR IGNORE` = local idempotency). `flush()` retries 5xx/429/network with delays 2,4,8,16,32 s per flush; exhausted items stay pending and are retried when `NWPathMonitor` reports connectivity or at next launch. 4xx (bad key, unverified sender) is permanent. With no verified recipient, alerts are kept and sent once an address is verified.
- `RecipientVerifier`: emails a CSPRNG 6-digit code to a new address; stores only a salted SHA-256 (15 min expiry, 5 attempts, 3 requests/hour). Alerts go only to the verified address.

## Background model
A regular app with `MenuBarExtra`; `applicationShouldTerminateAfterLastWindowClosed = false`; quitting while protected requires owner auth. Optional `SMAppService.mainApp` login item. A 30 s heartbeat in SQLite lets the next launch record a monitoring gap and (if enabled) resume protection only when the charger is connected.
