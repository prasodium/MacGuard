# Security

## Threat model
**Protects against:** opportunistic theft where the thief unplugs a running, unlocked Mac; casual forgery of alert requests; replay of captured requests; abuse of the email backend as a spam relay.
**Does not protect against:** a thief who powers off, force-quits, or removes all power; a thief with the owner's password; compromise of the Mac's user account (the HMAC secret and local DB are readable by that user); a compromised backend host.

## Controls
- **No privileged key in the client.** Only a per-installation random 256-bit secret, created on the Mac, stored in Keychain (`AfterFirstUnlockThisDeviceOnly`). The Resend key lives only in backend env. A test scans `Sources/` for provider keys.
- **Enrollment:** operator issues a single-use, 24 h token (only its SHA-256 is stored). Extracting a client secret yields access only to *that installation's* alerts to the fixed owner address, rate-limited.
- **Request auth:** `HMAC-SHA256(secret, METHOD\nPATH\nTS\nNONCE\nSHA256(body))`; ±5 min skew window; nonce replay cache (checked only after signature validation); constant-time compare; generic 401 responses.
- **Backend hardening:** strict payload validation (UUIDs, coordinate ranges, enums, lengths), 16 KB body cap, per-installation and enroll rate limits, recipient not client-controllable, generic error bodies, provider errors never forwarded, no header/token logging, idempotency keys prevent duplicate emails.
- **Transport:** client refuses non-HTTPS URLs (HTTP only for localhost in dev); deploy behind TLS.
- **Owner authentication:** `LocalAuthentication` (`deviceOwnerAuthentication`) gates disarm, alarm stop, and quitting while protected. MacGuard never sees or stores the macOS password and never fakes a login UI. If the Mac has no authentication configured the prompt is skipped so owners are never locked out. An app-level check is weaker than the OS lock and is documented as such.
- **Local data:** SQLite directory 0700 / file 0600; retention purge; "clear" actions. Not encrypted at rest beyond FileVault (documented trade-off).
- **One private API, documented:** `SACLockScreenImmediate` (login.framework, loaded with `dlopen`/`dlsym`) is used to lock the session because no public API exists. It is called only on a confirmed incident or an explicit test, failure falls back to a public CLI, and success is claimed only after CGSession confirms the lock. Risk: Apple may change/remove it; not App Store compatible. No root, no daemons, no anti-termination tricks.

## In-app email configuration
- `POST /v1/config/provider`, `/v1/config/recipient/request`, `/v1/config/recipient/confirm` are signed-request-only, rate-limited (20/h per installation; 3 codes/h per address) and need Touch ID/password in the app.
- A new recipient receives a 6-digit code (CSPRNG, stored only as a salted hash, 15 min expiry, 5 attempts). **Until verified it receives nothing.** On change, the previous address (or `OWNER_EMAIL`) is emailed a notice.
- The Brevo key is verified (`GET /v3/account`) before being saved and is never returned by any endpoint.
- **Residual risk:** whoever holds this Mac's installation secret (for example a thief with an unlocked session) can call these endpoints, because the backend cannot see the Touch ID prompt. They would also need to receive a code at the new address, and the old address is notified, but you should treat a change notice you did not make as an incident: re-enroll and rotate the Brevo key. If you want to forbid in-app changes entirely, set `OWNER_EMAIL` and `CONFIG_RATE_LIMIT_PER_HOUR=0` (disables them).

## Key lifecycle
Create: on enroll (client). Rotate/revoke: delete installation from `backend/data/state.json` (or re-enroll — replaces the secret) and "Unenroll" by deleting the Keychain items (`scripts/uninstall.sh`). Rotating the provider key (Brevo/Resend) needs only a backend env change. `/v1/info` is signed-request-only and returns just the provider name and a masked recipient.

## Known weaknesses
Backend state is a JSON file (single instance); in-memory rate limits/nonces reset on restart (replay still bounded by the 5-min window and email idempotency); no per-incident cap on follow-up count beyond rate limit.

Report vulnerabilities via a private GitHub security advisory on this repository.
