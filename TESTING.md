# Testing

```bash
scripts/test.sh   # backend (node:test) + Swift (Swift Testing)
```

## Results at the time of writing (macOS 27.0.1, arm64, Swift 6.4, CLT only)
- **Swift: 60 tests / 7 suites pass.** Power detector & monitor (connected, disconnected, fully charged, low battery, duplicate notifications, unknown, API failure, start-on-battery, transient disconnect, wake), state machine (arming, invalid transitions, duplicate suppression, forward-only flow, reconnection, unauthorized disarm, degradation/recovery), location (fresh, cached, timeout, permission denied, disabled, invalid coordinates, last-known, cancellation, map URL), notifications (payloads, retry/backoff, exhaustion, permanent errors, dedupe, offline resend, test email), theft response (alarm independent of email/location/lock failure, single execution per incident), security (HTTPS enforcement, signature vector shared with Node, DB permissions, no provider keys in source, log content, retention).
- **Backend: 15 tests pass.** Auth (bad/stale/replayed), validation, size limit, idempotency, enrollment, rate limit, provider failure hiding, templates (map link only for valid coords, escaping, labels), Resend request shape.
- **Real-hardware checks run** (`MacGuard --self-check --play --lock-test`): live IOKit power read, SQLite round-trip and 0600 file mode, Keychain round-trip, system sounds present, `NSSound.play()` accepted, GUI app launches without a crash report.
- **End-to-end** (`--self-check --e2e <url> <token>`): Swift client enrolls with, authenticates to, and sends test + incident alerts through the real Node backend (console provider); duplicate incident produced one email.

## Manual hardware checklist (NOT yet performed — mark when done)
- [ ] Unplug charger while armed → alarm within delay + one incident; replug → recorded, alarm continues
- [ ] 100 % charged & plugged: arming works, no false alarm
- [ ] Start app on battery: no alarm, cannot arm
- [ ] Close dashboard: still armed; menu bar shows status
- [ ] Quit while armed requires authentication; Disarm and Stop Alarm require authentication
- [ ] Alarm audible with muted output + "raise volume" on; with headphones (documented limit)
- [x] Screen lock: `MacGuard --self-check --lock-test` on macOS 27.0.1 → session locked, verified via CGSession (**locks your session; run deliberately**)
- [ ] Screen lock from a real theft incident (end to end) and on other macOS versions
- [ ] Location permission flow (grant/deny); Test Location accuracy; timeout with Wi-Fi off
- [ ] Real Resend: Test Email, incident email, follow-up, Wi-Fi off then on (queued → sent)
- [ ] Sleep/wake while armed (gap logged, power re-read); unplug during sleep → alert on wake
- [ ] Kill -9 then relaunch: gap logged, protection resumes only if charger connected
- [ ] Login item starts after login; signed + notarized build re-test
- [ ] VoiceOver pass, light/dark appearance review
- [ ] Idle CPU/energy in Activity Monitor over 1 h (target ≈ 0 % CPU; not yet measured)

## Known gaps
No XCUITest/UI tests; coordinator-level (AppCoordinator) logic is untested apart from its collaborators; no `.xcodeproj`; Resend delivery and the physical charger transition were not exercised; resource consumption not measured.
