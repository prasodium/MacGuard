# MacGuard — Smart Protection. Instant Alerts. Better Recovery.

A native macOS anti-theft utility. While **armed**, MacGuard watches the charger. If it is unplugged, it sounds a repeating alarm, asks macOS to lock the screen, tries to get the Mac's location, and emails you through a small authenticated backend. It also guides you through recovery with Apple's built-in **Find My**.

> **MacGuard is a deterrent and recovery aid, not a security boundary.** It cannot stop anyone from shutting the Mac down, force-quitting the app, or removing all power. See [Limitations](#limitations).

## Implementation status (honest)

| Area | Status |
|---|---|
| Power detection (IOKit read + change notifications + reconciliation poll, debounce, dedupe) | Implemented. Reading verified on real hardware; **physical unplug/replug NOT yet hardware-tested** |
| State machine, incidents, event log (SQLite), settings | Implemented, unit-tested |
| Alarm (repeat, volume boost, preview, authenticated stop) | Implemented; playback start verified on hardware, **audibility/muted-speaker cases untested** |
| Screen lock (private `SACLockScreenImmediate`, fallback `pmset displaysleepnow`, verified via CGSession) | Implemented; **verified on a real Mac (macOS 27.0.1): session reported locked**. Not tested on other macOS versions |
| Location (Core Location, timeout, cache/last-known, validation) | Implemented, unit-tested with mocks; **real fix & permission flow awaiting hardware validation** |
| Email backend (Node, HMAC auth, replay/rate-limit, idempotency, Brevo + Resend + console providers, HTML+text) | Implemented, 26 tests; in-app Brevo key + verified-recipient flow verified end to end against a fake Brevo (`scripts/e2e.sh`); Swift client ↔ backend verified end-to-end with the console provider. **Real Brevo/Resend delivery NOT verified** (no API key available during development; request shapes follow each provider's documented HTTP API) |
| Retry/outbox/offline queue, follow-ups | Implemented, unit-tested |
| In-app Brevo key + Gmail verification | Implemented and integration-tested against a **fake** Brevo; **not yet run against real Brevo** |
| Dashboard, Settings, History, 9-step onboarding, Find My guide, menu bar | Implemented; launch smoke-tested, **not visually reviewed or VoiceOver-audited** |
| Login item (`SMAppService`), restore-after-restart, sleep/wake handling | Implemented; **not hardware-tested** |
| `.xcodeproj` | **Not provided** – Xcode isn't installed on the dev machine; the project is a Swift package + `scripts/build_app.sh` (open `Package.swift` in Xcode to get a project) |
| Developer ID signing / notarization | Documented, **not performed** (ad-hoc signed only) |
| Pre-login / shutdown / sleep-time alarm | **Unavailable** (not possible for a user-space app) |

See [TESTING.md](TESTING.md) for exactly what was run.

## Features
- Armed monitoring that survives closing the dashboard (menu-bar app); optional start at login; optional resume after restart.
- Charger-state model: connected / disconnected / unknown, charging, fully charged. Unknown states and API errors **never** raise a theft alert — they degrade monitoring and show a warning.
- Configurable confirmation delay (immediate, 1, 3, 5, 10 s).
- Explicit confirmation to arm; refuses to arm if power state is unknown or the charger is unplugged.
- Alarm stop / disarm require owner authentication (Touch ID or macOS password via the system `LocalAuthentication` prompt; MacGuard never sees the password).
- Email: incident id, device, battery, power before/after, time zone, alarm & lock status, location (labelled FRESH / CACHED / LAST KNOWN, or "LOCATION UNAVAILABLE"), Apple Maps link only for valid coordinates, recovery steps.
- Follow-ups: none / one / periodic; stale or unchanged positions are skipped, never re-sent.
- Offline outbox with bounded exponential backoff; resumes on connectivity.

## Architecture
```
┌──────────────────────── MacGuard.app (Swift / SwiftUI) ───────────────────────┐
│ UI: Dashboard · Settings · History · Onboarding · Menu bar                     │
│ AppCoordinator ──► GuardStateMachine (pure)                                    │
│   │ PowerMonitor ◄─ IOKit notifications + 15 s reconcile + wake refresh        │
│   │      └ PowerTransitionDetector (pure: baseline, debounce, dedupe)          │
│   └ TheftResponseCoordinator ─┬ AlarmManager (never waits on anything)         │
│                               ├ ScreenLockService                              │
│                               ├ LocationService ─ CoreLocationProvider         │
│                               └ TheftNotificationService ─ outbox(SQLite)      │
│ SecurityEventStore (SQLite 0600) · Keychain (install id + HMAC secret)         │
└──────────────────────────────┬─────────────────────────────────────────────────┘
                               │ HTTPS, HMAC-signed (timestamp, nonce, body hash)
                  ┌────────────▼─────────────┐      ┌──────────────┐
                  │ backend (Node, no deps)  │─────►│ Resend API   │
                  │ auth · validate · limits │      └──────────────┘
                  └──────────────────────────┘ ─► owner's inbox only
```
Details: [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements
- macOS 13+ (minimum), Apple Silicon primary (built `arm64`). Developed on macOS 27.0, Swift 6.4, **Command Line Tools only** (no Xcode needed).
- Node ≥ 20 for the backend only. The app has no third-party dependencies.

## Build, test, run
```bash
scripts/test.sh                 # backend tests + Swift tests
scripts/build_app.sh debug      # → dist/MacGuard.app (ad-hoc signed)
open dist/MacGuard.app
dist/MacGuard.app/Contents/MacOS/MacGuard --self-check --play   # hardware smoke test
```
With full Xcode you can instead `open Package.swift`, choose the **MacGuard** scheme and run (location prompts need the signed `.app` bundle, so prefer `build_app.sh` for permission testing).

> **Toolchain note.** With only Command Line Tools, `@State` and Swift Testing macros have no compiler plugin by default. The UI uses a small `@Local` wrapper instead of `@State`, and `scripts/test.sh` loads the Swift Testing plugin explicitly. Both also work with full Xcode.

### Install
Copy `dist/MacGuard.app` to `/Applications`. The first launch of an ad-hoc-signed app requires right-click → Open. Then follow the in-app setup.

## Permissions
| Permission | Why | Notes |
|---|---|---|
| Location (`NSLocationUsageDescription`, entitlement `…personal-information.location`) | Include position in alerts | Optional; app works without it. Enable in System Settings → Privacy & Security → Location Services |
| Notifications | Local alarm banner | Optional |
| Login Items | Start at login | Toggle in Settings; user-approved in System Settings |
| Screen lock | None | Uses a private macOS call (see Limitations); falls back to display sleep, which locks only if *Require password* is set to immediately |

No Accessibility, Full Disk Access, or admin rights are requested. No privileged daemon is installed.

## Email provider & backend
See [DEPLOYMENT.md](DEPLOYMENT.md). Summary:
```bash
cd backend
export EMAIL_PROVIDER=brevo BREVO_API_KEY=xkeysib-xxx OWNER_EMAIL=you@example.com FROM_EMAIL="MacGuard <you@example.com>"   # FROM must be your verified Brevo sender
npm run issue-token      # prints a single-use enrollment token
npm start
```
In the app: Settings → Email → enter the HTTPS backend URL and token → Enroll → Send test email.

**Email** uses **Brevo** by default (free tier, no owned domain; the same method as the author's helper-store project). Everything can be configured from **Settings → Email**:
1. enroll this Mac with your backend;
2. paste your **Brevo API key** and verified sender address. The key is sent once over signed HTTPS, the backend checks it with Brevo and keeps it, and it is **never stored on this Mac** (a stolen Mac must not hold your email key);
3. enter your **Gmail** (any address works) and press *Send verification code*. Alerts go to it **only after you enter the 6-digit code emailed to it**; changing it needs Touch ID/password and notifies the previous address;
4. *Check connection* / *Send test email*.

Operators can instead set env vars on the backend (`EMAIL_PROVIDER` = `brevo`|`resend`|`console`, keys, `OWNER_EMAIL` as a trusted bootstrap recipient). Resend and console remain available that way.

Backend env vars (all optional if you configure from the app): `OWNER_EMAIL`, `FROM_EMAIL`, `BREVO_API_KEY`, `CONFIG_RATE_LIMIT_PER_HOUR`, `BREVO_API_BASE` (tests only), `RESEND_API_KEY`, `EMAIL_PROVIDER` (`brevo`|`resend`|`console`), `PORT`, `DATA_DIR`, `MAX_BODY_BYTES`, `CLOCK_SKEW_SECONDS`, `RATE_LIMIT_PER_MINUTE`, `ENROLL_RATE_LIMIT_PER_HOUR`.

## Limitations
- **Charger monitoring:** only detects changes while MacGuard runs. Process death, shutdown, or full power loss go unnoticed; a gap is logged on next start but never converted into a theft event. A Mac unplugged *while asleep* is treated as a real disconnection on wake.
- **Alarm:** can be inaudible (muted/headphones/volume), cannot run during sleep/shutdown/force-quit. Always stoppable by the owner; by default it also stops when the charger is reconnected (Settings → Alarm), while protection stays armed until you disarm.
- **Screen lock:** protects a running session only. macOS has no public "lock now" API, so MacGuard calls the private `SACLockScreenImmediate` (resolved at runtime; unsuitable for the App Store, may change in future macOS) and falls back to display sleep. Reported as *verified* only if macOS reports the session locked.
- **Location:** estimate from Wi-Fi/Core Location, needs permission and network; may be stale. Never IP-geolocated, never fabricated. Not continuous tracking.
- **Email:** "accepted" means the provider accepted the request; inbox delivery is not confirmed. A Mac that never reconnects can't send.
- **Pre-login:** MacGuard starts after you log in; it can't monitor before login.
- **Battery-only arming** is intentionally not supported: you must arm while on the charger.

## Find My recovery
Enable Find My Mac (+ Find My network), confirm the right Apple Account, check icloud.com/find, use Lost Mode, contact authorities if theft is suspected. MacGuard cannot read Find My locations and never asks for Apple credentials. **OPEN FIND MY** is in the dashboard.

## Privacy & data
Everything stays on the Mac except what you send to *your* backend/provider on an incident. See [PRIVACY.md](PRIVACY.md). Event log retention default 90 days, location history 7 days (both configurable); "Clear" buttons in Settings.

## Troubleshooting
- *"Cannot arm"* — charger unplugged or power unreadable; plug in and check Dashboard → Monitoring.
- *Location unavailable* — grant permission in System Settings; run **Test Location**. Unsigned dev runs (bare binary) can't get a prompt; use the `.app`.
- *Email not arriving* — Test Email result is shown on the dashboard; check spam, backend logs, domain verification in Resend. 401 = re-enroll.
- *Screen lock "unverified"* — the private call was unavailable and the fallback only slept the display; set Lock Screen → Require password → Immediately.
- *Login item not starting* — approve it in System Settings → General → Login Items.

## Release, signing, notarization
`SIGN_IDENTITY="Developer ID Application: …" scripts/package.sh` signs with hardened runtime and zips; then `xcrun notarytool submit … --wait` and `xcrun stapler staple`. Not performed for this repository's current state; test location, login item and sleep/wake with the signed build (they can behave differently from debug/ad-hoc).

## Uninstall
`scripts/uninstall.sh` (disarm first). Removes the app, `~/Library/Application Support/MacGuard`, preferences, Keychain items.

## Known issues
See [TESTING.md](TESTING.md#known-gaps).
