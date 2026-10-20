# Deployment

## Backend (any Node ≥ 20 host with HTTPS)
1. Pick a provider (`EMAIL_PROVIDER`):
   - **brevo** (default, free tier, no owned domain): create an account, verify one *sender address* by email link, create an API key. Set `BREVO_API_KEY`; `FROM_EMAIL` must be that verified sender.
   - **resend**: verify a sending domain, create an API key. Set `RESEND_API_KEY`; `FROM_EMAIL` on that domain.
   - **console**: development only.
2. Minimum: `PORT`, `DATA_DIR` (persistent volume, it holds the saved key and verified recipient). Everything else can be done from the app (Settings → Email → Brevo key, then verify your Gmail). Optionally pre-set `EMAIL_PROVIDER`, the matching key, `FROM_EMAIL` and `OWNER_EMAIL` (a trusted bootstrap recipient). See `backend/.env.example`.
   Keys saved from the app live in `DATA_DIR/state.json` (mode 0600); protect that volume and back it up like a secret.
3. `cd backend && npm start` (no `npm install` needed — no dependencies). Run under a process manager (systemd/Fly/Render/Railway) behind a TLS terminator; do **not** expose plain HTTP.
4. `DATA_DIR=… npm run issue-token` → paste token into the app (Settings → Email). Tokens are single-use and expire in 24 h.
5. Check `GET /healthz`; in the app open Settings → Email → **Check connection** (shows method + masked recipient), then **Send test email**.
Local development: `EMAIL_PROVIDER=console OWNER_EMAIL=a@b.c FROM_EMAIL=x@y.z npm start` and use `http://localhost:8787` (HTTP is allowed for localhost only).

## App release
`scripts/package.sh` → `dist/MacGuard-<version>.zip` + SHA-256. For distribution outside your own machine: Apple Developer ID certificate → `SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package.sh` → `xcrun notarytool submit dist/MacGuard-0.1.0.zip --keychain-profile AC --wait` → `xcrun stapler staple dist/MacGuard.app`. Re-test location permission, login item, and sleep/wake on the signed build.
