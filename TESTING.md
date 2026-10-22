# Testing

```bash
scripts/test.sh   # Swift tests (Swift Testing)
```

## Results at the time of writing (macOS 27.0.1, arm64, Swift 6.4, Command Line Tools only)
- **99 tests / 14 suites pass**, including:
  - power detector & monitor (connected, disconnected, fully charged, low battery, duplicate notifications, unknown, API failure, start-on-battery, transient disconnect, wake)
  - state machine, including repeated unplug/replug cycles that must alarm every time
  - location (fresh, cached, timeout, denied, invalid coordinates, last-known, cancellation)
  - Brevo mailer (request shape, headers, sender parsing, HTTPS-only, error mapping, key storage, key verification)
  - recipient verification (code emailed, hash-only storage, expiry, 5-attempt lockout, single use, rate limit, invalid addresses)
  - notification outbox (backoff, exhaustion, permanent errors, dedupe, offline resend, alerts wait for a verified address)
  - repeat while unplugged (email every interval counted from the unplug, stops and resets when the charger is reconnected, other modes do not repeat, the 0.2.0 "wait between emails" setting converts to a repeat interval)
  - one combined alert email (no separate location email), fresh location emailed when the internet returns during a theft, queued location updates collapse to the newest by sequence number, the 0.2.0/0.2.1 "one follow-up" mode converts to the single email
  - found my Mac (cancels every unsent email for that incident only, explains it in the status email, keep tracking restarts the timer from now instead of a catch-up burst)
  - email templates (map link only for valid coordinates, honest FRESH/CACHED/LAST KNOWN labels, escaping, required fields)
  - theft response (alarm independent of email/location/lock failure; one execution per incident)
  - security (DB permissions, no key-shaped strings in source, only `BrevoMailer` references Brevo, settings migration)
- **Real-hardware checks run** (`MacGuard --self-check --play --lock-test`): live IOKit power read, SQLite round-trip and 0600 mode, Keychain round-trip, system sounds present, `NSSound.play()` accepted, **screen lock verified locked via CGSession**, GUI launches without a crash report.
- **Real network check:** Brevo's `/v3/account` and `/v3/smtp/email` endpoints exist and return the error shape the app parses (`{"message","code"}`, HTTP 401 for an invalid key). **No real Brevo key was available during development, so these automated tests never sent a real email. The owner has since reported that real alert emails through their own Brevo account work; that was observed by the owner and is not part of the automated tests.**

## Manual hardware checklist (NOT yet performed unless ticked)
- [ ] Settings → Email: save a real Brevo key + verified sender; verify your Gmail with the emailed code; Send test email arrives
- [ ] Unplug charger while armed → alarm + one incident + alert email; replug → alarm stops; unplug again → alarms again
- [ ] 100 % charged & plugged: arming works, no false alarm; start app on battery: no alarm, cannot arm
- [ ] Close dashboard: still armed; menu bar shows status; quit while armed requires authentication
- [ ] Alarm audible with muted output + "raise volume" on; headphones (documented limit)
- [x] Screen lock via `--lock-test` on macOS 27.0.1 (locks your session; run deliberately)
- [ ] Screen lock from a real incident, and on other macOS versions
- [ ] Location permission flow (grant/deny); Test Location accuracy; timeout with Wi-Fi off
- [ ] Wi-Fi off during an incident, then on: queued alert is sent
- [ ] Sleep/wake while armed (gap logged); unplug during sleep → alert on wake
- [ ] kill -9 then relaunch: gap logged, protection resumes only if the charger is connected
- [ ] Login item starts after login; signed + notarized build re-test
- [ ] VoiceOver pass, light/dark review; idle CPU/energy over 1 h (not measured)

## Known gaps
No UI tests; `AppCoordinator` glue is covered by an integration test that mirrors it; no `.xcodeproj`; real Brevo delivery and the physical charger transition were not exercised; resource use not measured.
