#!/usr/bin/env bash
# Builds MacGuard.app with SwiftPM (no full Xcode required) and code-signs it.
# Usage: scripts/build_app.sh [debug|release]   Env: SIGN_IDENTITY (default "-" = ad-hoc)
#   SIGN_KEYCHAIN: keychain holding a self-signed identity named by SIGN_IDENTITY. Ad-hoc builds get a new identity on every
#   build, so macOS forgets the Location permission after each update; a fixed identity keeps it.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
IDENTITY="${SIGN_IDENTITY:--}"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/MacGuard"
APP="dist/MacGuard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacGuard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
OPTS=()
if [ -n "${SIGN_KEYCHAIN:-}" ]; then
  security unlock-keychain -p "${SIGN_KEYCHAIN_PASSWORD:-}" "$SIGN_KEYCHAIN"
  OPTS=(--keychain "$SIGN_KEYCHAIN")      # self-signed: no timestamp, no hardened runtime
elif [ "$IDENTITY" != "-" ]; then
  OPTS=(--options runtime --timestamp)    # Developer ID
fi
codesign --force --sign "$IDENTITY" ${OPTS[@]+"${OPTS[@]}"} --entitlements Resources/MacGuard.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP (signed with identity: $IDENTITY)"
