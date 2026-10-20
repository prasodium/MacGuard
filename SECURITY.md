# Security

## Threat model
**Protects against:** opportunistic theft where the thief unplugs a running Mac (alarm, lock request, alert); alerts being sent to an address the owner has not proven they control.
**Does not protect against:** a thief who powers off, force-quits, or removes all power; a thief who knows the owner's password; malware running as the owner (it can read what the owner can read, including Keychain items the app can read).

## The Brevo key (main trade-off)
The app sends mail directly through Brevo, so **the Brevo API key lives on this Mac**, in the macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by this app while the Mac is locked so alerts can still be sent, never synced or backed up off-device). It is never written to files, logs, settings, the SQLite database, or the repository (a test scans the source for key-shaped strings and provider hostnames outside `BrevoMailer`).
**Risk:** someone with access to your logged-in account could use the key to send mail through your Brevo account. **Mitigations:** the screen lock and your account password; saving/removing the key needs Touch ID/password; you can delete or regenerate the key in Brevo at any time (do this if the Mac is stolen and not recovered). Prefer a key used only for MacGuard, and a Brevo sender restricted to one verified address.

## Controls
- **Verified recipient:** alerts go only to an address that has confirmed an emailed 6-digit code (CSPRNG; stored only as a salted hash; 15 min expiry; 5 attempts; 3 code requests/hour). Unverified alerts are queued, never sent. Changing the address needs owner authentication and notifies the previous address.
- **Transport:** HTTPS only; the mailer refuses any other scheme.
- **Owner authentication:** `LocalAuthentication` (`deviceOwnerAuthentication`) gates disarm, alarm stop, quit while protected, and saving/removing the key or changing the recipient. MacGuard never sees or stores the macOS password and never fakes a login UI. If the Mac has no authentication configured the prompt is skipped so owners are never locked out. This is weaker than the OS lock and is documented as such.
- **Local data:** SQLite directory 0700 / file 0600; retention purge; "clear" actions. Not encrypted at rest beyond FileVault.
- **One private API, documented:** `SACLockScreenImmediate` (login.framework via `dlopen`/`dlsym`) locks the session because macOS has no public API. It runs only on a confirmed incident or an explicit test, falls back to a public CLI, and a lock is claimed only after CGSession confirms it. Risk: Apple may change/remove it; not App Store compatible.
- No root, no daemons, no anti-termination tricks.

Report vulnerabilities via a private GitHub security advisory on this repository.
