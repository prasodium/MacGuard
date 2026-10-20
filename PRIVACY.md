# Privacy

## Stays on your Mac
Event log, incidents, the alert queue, last-known location (SQLite in `~/Library/Application Support/MacGuard`, owner-only), settings (UserDefaults), and the Brevo API key (Keychain). Defaults: events 90 days, location history 7 days; configurable; one-click clear.

## Sent off the Mac (only if email alerts are on)
Straight to **Brevo** (you hold the account), which delivers to **your verified address**: on an incident, test, or status event — incident id, device name/model, macOS version, battery %, power before/after, timestamps & time zone, alarm/lock status, and, if available and enabled, latitude, longitude, accuracy, fix time and freshness. Verification codes are emailed the same way. Brevo and your mail provider handle that data under their own policies. Nothing is sent when email alerts are off.

## Not collected
Passwords, Apple Account data, files, browsing history, contacts, IP-based locations, analytics, or telemetry. There is no MacGuard server. Location is requested only for a test or an incident, never continuously.
