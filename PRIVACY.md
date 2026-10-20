# Privacy

## Stays on your Mac
Event log, incidents, outbox, last-known location (SQLite in `~/Library/Application Support/MacGuard`, owner-only), settings (UserDefaults), the HMAC secret (Keychain). Defaults: events 90 days, location history 7 days; configurable; one-click clear.

## Sent off the Mac (only if email is enabled)
To **your** backend, on an incident/test/status event: incident id, device name/model, macOS version, battery %, power before/after, timestamps & time zone, alarm/lock status, and — if available and enabled — latitude, longitude, accuracy, fix time, freshness. The backend forwards this to Resend to email **your** configured address. Resend and your host see this data under their own policies. Nothing is sent when email is off.

## Not collected
Passwords, Apple Account data, files, browsing history, contacts, IP-based locations, analytics, or telemetry. Location is requested only for a test or an incident, never continuously.

## Backend retention
`state.json` holds installation ids/secrets, hashed tokens and idempotency records (no email bodies or coordinates). Provider-side retention is governed by Resend.
