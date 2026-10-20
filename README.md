# MacGuard — Smart Protection. Instant Alerts. Better Recovery.

A native macOS anti-theft utility. While **armed**, MacGuard watches the charger. If it is unplugged, it sounds a repeating alarm, asks macOS to lock the screen, tries to get the Mac's location, and emails you directly through Brevo. It also guides you through recovery with Apple's built-in **Find My**.

> **MacGuard is a deterrent and recovery aid, not a security boundary.** It cannot stop anyone from shutting the Mac down, force-quitting the app, or removing all power. See [Limitations](#limitations).

## Implementation status (honest)

| Area | Status |
|---|---|
| Power detection (IOKit read + change notifications + reconciliation poll, debounce, dedupe) | Implemented. Reading verified on real hardware; **physical unplug/replug NOT yet hardware-tested** |
| State machine, incidents, event log (SQLite), settings | Implemented, unit-tested |
| Alarm (repeat, volume boost, preview, authenticated stop) | Implemented; playback start verified on hardware, **audibility/muted-speaker cases untested** |
| Screen lock (private `SACLockScreenImmediate`, fallback `pmset displaysleepnow`, verified via CGSession) | Implemented; **verified on a real Mac (macOS 27.0.1): session reported locked**. Not tested on other macOS versions |
| Location (Core Location, timeout, cache/last-known, validation) | Implemented, unit-tested with mocks; **real fix & permission flow awaiting hardware validation** |
| Email: direct to Brevo (key in Keychain), verified Gmail via emailed code, HTML+text templates, offline queue + backoff | Implemented, unit-tested; the Brevo endpoints were checked against the live API with a dummy key. **A real email has NOT been sent yet** (no key available during development) |
| Retry/outbox/offline queue, follow-ups | Implemented, unit-tested |
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
│                               └ TheftNotificationService ─ outbox (SQLite)     │
│                                      └ BrevoMailer + EmailTemplates            │
│ RecipientVerifier (emailed 6-digit code) · SecurityEventStore (SQLite 0600)    │
│ Keychain (Brevo API key)                                                       │
└───────────────────────────────┬────────────────────────────────────────────────┘
                                │ HTTPS  api.brevo.com
                                ▼
                  Brevo ──► your verified address (Gmail)
```
No server of your own is needed. Details: [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements
- macOS 13+ (minimum), Apple Silicon primary (built `arm64`). Developed on macOS 27.0, Swift 6.4, **Command Line Tools only** (no Xcode needed).
- A free [Brevo](https://www.brevo.com) account for email alerts (optional). The app has no third-party dependencies and needs no server.

## Build, test, run
```bash
scripts/test.sh                 # Swift tests
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

## Email setup (Settings → Email)
1. Create a free Brevo account, verify **one sender address** (no domain needed), and create an API key (the **Get a key…** button opens Brevo's page).
2. Paste the key and the verified sender, press **Save**. The key is checked with Brevo and stored **only in your Mac's Keychain** (needs Touch ID/password).
3. Enter your **Gmail** (any address works), press **Send code**, type the 6-digit code from the email, press **Verify**. Alerts go to an address only after it is verified.
4. Press **Send test email**.

The trade-off of having the key on the Mac is explained in [SECURITY.md](SECURITY.md): if the Mac is stolen and not recovered, delete the key in Brevo.

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
Everything stays on the Mac except the alert emails sent through your Brevo account. See [PRIVACY.md](PRIVACY.md). Event log retention default 90 days, location history 7 days (both configurable); "Clear" buttons in Settings.

## Troubleshooting
- *"Cannot arm"* — charger unplugged or power unreadable; plug in and check Dashboard → Monitoring.
- *Location unavailable* — grant permission in System Settings; run **Test Location**. Unsigned dev runs (bare binary) can't get a prompt; use the `.app`.
- *Email not arriving* — the Test result is shown in Settings → Email / Tests. 401 = bad key; 400 = the sender is not verified in Brevo; also check spam and Brevo's logs.
- *Screen lock "unverified"* — the private call was unavailable and the fallback only slept the display; set Lock Screen → Require password → Immediately.
- *Login item not starting* — approve it in System Settings → General → Login Items.

## Release, signing, notarization
`SIGN_IDENTITY="Developer ID Application: …" scripts/package.sh` signs with hardened runtime and zips; then `xcrun notarytool submit … --wait` and `xcrun stapler staple`. Not performed for this repository's current state; test location, login item and sleep/wake with the signed build (they can behave differently from debug/ad-hoc).

## Uninstall
`scripts/uninstall.sh` (disarm first). Removes the app, `~/Library/Application Support/MacGuard`, preferences and the Keychain item; delete the key in Brevo too.

## Known issues
See [TESTING.md](TESTING.md#known-gaps).
