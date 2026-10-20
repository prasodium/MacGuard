#!/usr/bin/env bash
# Produces dist/MacGuard-<version>.zip (and notarization-ready archive when SIGN_IDENTITY is a Developer ID).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build_app.sh release
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ditto -c -k --keepParent dist/MacGuard.app "dist/MacGuard-$VERSION.zip"
shasum -a 256 "dist/MacGuard-$VERSION.zip" | tee "dist/MacGuard-$VERSION.zip.sha256"
echo "Notarize (Developer ID builds only): xcrun notarytool submit dist/MacGuard-$VERSION.zip --keychain-profile <profile> --wait && xcrun stapler staple dist/MacGuard.app"
