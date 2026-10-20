#!/usr/bin/env bash
# Builds MacGuard.app with SwiftPM (no full Xcode required) and code-signs it.
# Usage: scripts/build_app.sh [debug|release]   Env: SIGN_IDENTITY (default "-" = ad-hoc)
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
[ "$IDENTITY" != "-" ] && OPTS=(--options runtime --timestamp)
codesign --force --sign "$IDENTITY" ${OPTS[@]+"${OPTS[@]}"} --entitlements Resources/MacGuard.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP (signed with identity: $IDENTITY)"
