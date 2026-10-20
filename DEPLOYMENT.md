# Deployment

## Backend (any Node ≥ 20 host with HTTPS)
1. Create a Resend account, verify a sending domain, create an API key (sending access).
2. Set env: `OWNER_EMAIL`, `FROM_EMAIL` (on the verified domain), `RESEND_API_KEY`, optionally `PORT`, `DATA_DIR` (persistent volume).
3. `cd backend && npm start` (no `npm install` needed — no dependencies). Run under a process manager (systemd/Fly/Render/Railway) behind a TLS terminator; do **not** expose plain HTTP.
4. `DATA_DIR=… npm run issue-token` → paste token into the app (Settings → Email). Tokens are single-use and expire in 24 h.
5. Check `GET /healthz`; press **Send test email** in the app.
Local development: `EMAIL_PROVIDER=console OWNER_EMAIL=a@b.c FROM_EMAIL=x@y.z npm start` and use `http://localhost:8787` (HTTP is allowed for localhost only).

## App release
`scripts/package.sh` → `dist/MacGuard-<version>.zip` + SHA-256. For distribution outside your own machine: Apple Developer ID certificate → `SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package.sh` → `xcrun notarytool submit dist/MacGuard-0.1.0.zip --keychain-profile AC --wait` → `xcrun stapler staple dist/MacGuard.app`. Re-test location permission, login item, and sleep/wake on the signed build.
