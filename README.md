<a id="top"></a>

<div align="center">

<img src="assets/icon.png" alt="MacGuard app icon" width="128" height="128">

<h1>MacGuard</h1>

<p><strong>Smart Protection. Instant Alerts. Better Recovery.</strong></p>

<p>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-000000?logo=apple&logoColor=white" alt="Platform: macOS 13 and later">
  <img src="https://img.shields.io/badge/chip-Apple%20Silicon-555555" alt="Chip: Apple Silicon">
  <img src="https://img.shields.io/badge/language-Swift-F05138?logo=swift&logoColor=white" alt="Language: Swift">
  <img src="https://img.shields.io/badge/UI-SwiftUI-0A84FF" alt="UI: SwiftUI">
  <img src="https://img.shields.io/badge/email-Brevo-0B996E" alt="Email: Brevo">
  <img src="https://img.shields.io/badge/status-beta-orange" alt="Status: beta">
  <img src="https://img.shields.io/badge/license-not%20specified-lightgrey" alt="License: not specified">
</p>

<p>
  <a href="#features">Features</a> &middot;
  <a href="#build-test-run">Build</a> &middot;
  <a href="#permissions">Permissions</a> &middot;
  <a href="#email-setup-settings--email">Email setup</a> &middot;
  <a href="#limitations">Limitations</a> &middot;
  <a href="#troubleshooting">Troubleshooting</a>
</p>

</div>

A native macOS anti-theft utility. While **armed**, MacGuard watches the charger. If it is unplugged, it sounds a repeating alarm, asks macOS to lock the screen, tries to get the Mac's location, and emails you directly through Brevo. It also guides you through recovery with Apple's built-in **Find My**.

> **MacGuard is a deterrent and recovery aid, not a security boundary.** It cannot stop anyone from shutting the Mac down, force-quitting the app, or removing all power. See [Limitations](#limitations).

## At a glance

| Section | What you will find | Jump to |
|---|---|---|
| Implementation status (honest) | What is implemented, tested on real hardware, or still unverified | [Details](#implementation-status-honest) |
| Features | Monitoring, alarm, authentication, email, follow-ups, offline queue | [Details](#features) |
| Architecture | Diagram of the app, its components and the Brevo connection | [Details](#architecture) |
| Requirements | Supported macOS versions, toolchain, optional Brevo account | [Details](#requirements) |
| Build, test, run | Commands to test, build and smoke-test the app, plus how to install it | [Details](#build-test-run) |
| Permissions | What macOS permissions are used and why | [Details](#permissions) |
| Email setup (Settings → Email) | Four steps from a Brevo key to a verified test email | [Details](#email-setup-settings--email) |
| Limitations | What MacGuard cannot do: monitoring, alarm, lock, location, email | [Details](#limitations) |
| Find My recovery | How to use Apple's Find My alongside MacGuard | [Details](#find-my-recovery) |
| Privacy & data | What stays on the Mac and how long it is kept | [Details](#privacy--data) |
| Troubleshooting | Symptom-by-symptom fixes | [Details](#troubleshooting) |
| Release, signing, notarization | Developer ID signing and notarization steps | [Details](#release-signing-notarization) |
| Uninstall | One script that removes the app and its data | [Details](#uninstall) |
| Known issues | Pointer to the known gaps list | [Details](#known-issues) |

<details>
<summary><strong>Table of contents</strong></summary>

- [At a glance](#at-a-glance)
- [Implementation status (honest)](#implementation-status-honest)
- [Features](#features)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Build, test, run](#build-test-run)
  - [Install](#install)
- [Permissions](#permissions)
- [Email setup (Settings → Email)](#email-setup-settings--email)
- [Limitations](#limitations)
- [Find My recovery](#find-my-recovery)
- [Privacy & data](#privacy--data)
- [Troubleshooting](#troubleshooting)
- [Release, signing, notarization](#release-signing-notarization)
- [Uninstall](#uninstall)
- [Known issues](#known-issues)

</details>

<p align="right"><a href="#top">Back to top</a></p>

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

<p align="right"><a href="#top">Back to top</a></p>

## Features

| Feature | Details |
|---|---|
| Background protection | Armed monitoring that survives closing the dashboard (menu-bar app); optional start at login; optional resume after restart. |
| Charger-state model | connected / disconnected / unknown, charging, fully charged. Unknown states and API errors **never** raise a theft alert — they degrade monitoring and show a warning. |
| Confirmation delay | Configurable (immediate, 1, 3, 5, 10 s). |
| Arming | Explicit confirmation to arm; refuses to arm if power state is unknown or the charger is unplugged. |
| Owner authentication | Alarm stop / disarm require owner authentication (Touch ID or macOS password via the system `LocalAuthentication` prompt; MacGuard never sees the password). |
| Alert email | incident id, device, battery, power before/after, time zone, alarm & lock status, location (labelled FRESH / CACHED / LAST KNOWN, or "LOCATION UNAVAILABLE"), Apple Maps link only for valid coordinates, recovery steps. |
| Follow-ups | none / one / periodic; stale or unchanged positions are skipped, never re-sent. |
| Email delay | Optional minimum wait between alert emails (1 to 60 min, off by default). The first alert is immediate; later ones are held, not lost, and only the newest location update is sent. Test emails and verification codes are not delayed. |
| Offline outbox | Bounded exponential backoff; resumes on connectivity. |

<p align="right"><a href="#top">Back to top</a></p>

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

<p align="right"><a href="#top">Back to top</a></p>

## Requirements

| Item | Details |
|---|---|
| Operating system and toolchain | macOS 13+ (minimum), Apple Silicon primary (built `arm64`). Developed on macOS 27.0, Swift 6.4, **Command Line Tools only** (no Xcode needed). |
| Email alerts (optional) | A free [Brevo](https://www.brevo.com) account. The app has no third-party dependencies and needs no server. |

<p align="right"><a href="#top">Back to top</a></p>

## Build, test, run

<details>
<summary>Show build, test and toolchain details (contributors)</summary>

```bash
scripts/test.sh                 # Swift tests
scripts/build_app.sh debug      # → dist/MacGuard.app (ad-hoc signed)
open dist/MacGuard.app
dist/MacGuard.app/Contents/MacOS/MacGuard --self-check --play   # hardware smoke test
```

With full Xcode you can instead `open Package.swift`, choose the **MacGuard** scheme and run (location prompts need the signed `.app` bundle, so prefer `build_app.sh` for permission testing).

> **Toolchain note.** With only Command Line Tools, `@State` and Swift Testing macros have no compiler plugin by default. The UI uses a small `@Local` wrapper instead of `@State`, and `scripts/test.sh` loads the Swift Testing plugin explicitly. Both also work with full Xcode.

</details>

### Install

| Option | Steps |
|---|---|
| Disk image | Download `MacGuard-<version>.dmg` from the [latest release](https://github.com/prasodium/MacGuard/releases/latest), open it and drag **MacGuard** onto **Applications**. |
| Installer | Download `MacGuard-<version>.pkg` and double-click it (right-click → Open the first time). It always installs to `/Applications`. |
| Built from source | Copy `dist/MacGuard.app` to `/Applications`. |

The first launch of an ad-hoc-signed app requires right-click → Open. Then follow the in-app setup.

<p align="right"><a href="#top">Back to top</a></p>

## Permissions

| Permission | Why | Notes |
|---|---|---|
| Location (`NSLocationUsageDescription`, entitlement `…personal-information.location`) | Include position in alerts | Optional; app works without it. Enable in System Settings → Privacy & Security → Location Services |
| Notifications | Local alarm banner | Optional |
| Login Items | Start at login | Toggle in Settings; user-approved in System Settings |
| Screen lock | None | Uses a private macOS call (see [Limitations](#limitations)); falls back to display sleep, which locks only if *Require password* is set to immediately |

No Accessibility, Full Disk Access, or admin rights are requested. No privileged daemon is installed.

<p align="right"><a href="#top">Back to top</a></p>

## Email setup (Settings → Email)

1. Create a free Brevo account, verify **one sender address** (no domain needed), and create an API key (the **Get a key…** button opens Brevo's page).
2. Paste the key and the verified sender, press **Save**. The key is checked with Brevo and stored **only in your Mac's Keychain** (needs Touch ID/password).
3. Enter your **Gmail** (any address works), press **Send code**, type the 6-digit code from the email, press **Verify**. Alerts go to an address only after it is verified.
4. Press **Send test email**.

The trade-off of having the key on the Mac is explained in [SECURITY.md](SECURITY.md): if the Mac is stolen and not recovered, delete the key in Brevo.

<p align="right"><a href="#top">Back to top</a></p>

## Limitations

| Area | Limitation |
|---|---|
| Charger monitoring | Only detects changes while MacGuard runs. Process death, shutdown, or full power loss go unnoticed; a gap is logged on next start but never converted into a theft event. A Mac unplugged *while asleep* is treated as a real disconnection on wake. |
| Alarm | Can be inaudible (muted/headphones/volume), cannot run during sleep/shutdown/force-quit. Always stoppable by the owner; by default it also stops when the charger is reconnected (Settings → Alarm), while protection stays armed until you disarm. |
| Screen lock | Protects a running session only. macOS has no public "lock now" API, so MacGuard calls the private `SACLockScreenImmediate` (resolved at runtime; unsuitable for the App Store, may change in future macOS) and falls back to display sleep. Reported as *verified* only if macOS reports the session locked. |
| Location | Estimate from Wi-Fi/Core Location, needs permission and network; may be stale. Never IP-geolocated, never fabricated. Not continuous tracking. |
| Email | "accepted" means the provider accepted the request; inbox delivery is not confirmed. A Mac that never reconnects can't send. |
| Pre-login | MacGuard starts after you log in; it can't monitor before login. |
| Battery-only arming | Intentionally not supported: you must arm while on the charger. |

<p align="right"><a href="#top">Back to top</a></p>

## Find My recovery

Enable Find My Mac (+ Find My network), confirm the right Apple Account, check icloud.com/find, use Lost Mode, contact authorities if theft is suspected. MacGuard cannot read Find My locations and never asks for Apple credentials. **OPEN FIND MY** is in the dashboard.

<p align="right"><a href="#top">Back to top</a></p>

## Privacy & data

Everything stays on the Mac except the alert emails sent through your Brevo account. See [PRIVACY.md](PRIVACY.md). Event log retention default 90 days, location history 7 days (both configurable); "Clear" buttons in Settings.

<p align="right"><a href="#top">Back to top</a></p>

## Troubleshooting

| Symptom | What to do |
|---|---|
| *"Cannot arm"* | Charger unplugged or power unreadable; plug in and check Dashboard → Monitoring. |
| *Location unavailable* | Grant permission in System Settings; run **Test Location**. Unsigned dev runs (bare binary) can't get a prompt; use the `.app`. |
| *Email not arriving* | The Test result is shown in Settings → Email / Tests. 401 = bad key; 400 = the sender is not verified in Brevo; also check spam and Brevo's logs. |
| *Screen lock "unverified"* | The private call was unavailable and the fallback only slept the display; set Lock Screen → Require password → Immediately. |
| *Login item not starting* | Approve it in System Settings → General → Login Items. |

<p align="right"><a href="#top">Back to top</a></p>

## Release, signing, notarization

<details>
<summary>Show release and notarization steps (contributors)</summary>

`SIGN_IDENTITY="Developer ID Application: …" scripts/package.sh` signs with hardened runtime and builds the `.dmg`, `.pkg` and `.zip` in `dist/` (plus `SHA256SUMS.txt`; set `INSTALLER_IDENTITY="Developer ID Installer: …"` to sign the `.pkg`); then `xcrun notarytool submit … --wait` and `xcrun stapler staple` (for the `.dmg`). Not performed for this repository's current state; test location, login item and sleep/wake with the signed build (they can behave differently from debug/ad-hoc).

</details>

<p align="right"><a href="#top">Back to top</a></p>

## Uninstall

| Step | Details |
|---|---|
| Disarm | Disarm protection first. |
| Run | `scripts/uninstall.sh` |
| What it removes | The app, `~/Library/Application Support/MacGuard`, preferences and the Keychain item; delete the key in Brevo too. |

<p align="right"><a href="#top">Back to top</a></p>

## Known issues

See [TESTING.md](TESTING.md#known-gaps).

<p align="right"><a href="#top">Back to top</a></p>
