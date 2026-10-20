#!/usr/bin/env bash
# Real integration test: Swift client <-> Node backend <-> fake Brevo. Covers key save, emailed code, verification, alert routing.
set -euo pipefail
cd "$(dirname "$0")/.."
W=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$W"' EXIT
scripts/build_app.sh debug >/dev/null
( cd backend
  node scripts/fake-brevo.js 8798 "$W/mail.jsonl" >/dev/null & sleep 0.5
  export DATA_DIR="$W/data" PORT=8799 EMAIL_PROVIDER=brevo BREVO_API_BASE=http://127.0.0.1:8798   # no key, no owner: configure from the app
  TOKEN=$(node scripts/issue-token.js | tail -1)
  node src/server.js >"$W/server.log" 2>&1 & sleep 1
  ../dist/MacGuard.app/Contents/MacOS/MacGuard --self-check --e2e http://127.0.0.1:8799 "$TOKEN" --mail-log "$W/mail.jsonl" | grep -E "e2e|SELF"
)
