#!/usr/bin/env bash
# Builds the release app and three installable files in dist/:
#   MacGuard-<version>.dmg   open it, drag MacGuard to Applications
#   MacGuard-<version>.pkg   double-click installer (installs to /Applications)
#   MacGuard-<version>.zip   plain archive
# plus SHA256SUMS.txt.
# Env: SIGN_IDENTITY       "Developer ID Application: ..." (default "-" = ad hoc)
#      INSTALLER_IDENTITY  "Developer ID Installer: ..."  (optional; signs the .pkg)
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build_app.sh release
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP=dist/MacGuard.app
OUT=dist
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
rm -f "$OUT"/MacGuard-"$VERSION".{zip,dmg,pkg} "$OUT"/SHA256SUMS.txt "$OUT"/MacGuard-"$VERSION".zip.sha256

# zip
ditto -c -k --keepParent "$APP" "$OUT/MacGuard-$VERSION.zip"

# dmg: the app next to an Applications shortcut
mkdir "$WORK/dmg" && cp -R "$APP" "$WORK/dmg/" && ln -s /Applications "$WORK/dmg/Applications"
hdiutil create -volname "MacGuard $VERSION" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$OUT/MacGuard-$VERSION.dmg" >/dev/null
[ "${SIGN_IDENTITY:--}" != "-" ] && codesign --force --sign "$SIGN_IDENTITY" --timestamp "$OUT/MacGuard-$VERSION.dmg"

# pkg: always installs to /Applications, even if another copy of the app exists elsewhere
mkdir -p "$WORK/root/Applications" && cp -R "$APP" "$WORK/root/Applications/"
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"
PKGSIGN=(); [ -n "${INSTALLER_IDENTITY:-}" ] && PKGSIGN=(--sign "$INSTALLER_IDENTITY")
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --install-location / \
  --identifier com.harprosad.macguard.pkg --version "$VERSION" ${PKGSIGN[@]+"${PKGSIGN[@]}"} "$OUT/MacGuard-$VERSION.pkg" >/dev/null

(cd "$OUT" && shasum -a 256 "MacGuard-$VERSION.dmg" "MacGuard-$VERSION.pkg" "MacGuard-$VERSION.zip" | tee SHA256SUMS.txt)
echo "Notarize (Developer ID builds only): xcrun notarytool submit $OUT/MacGuard-$VERSION.dmg --keychain-profile <profile> --wait && xcrun stapler staple $OUT/MacGuard-$VERSION.dmg"
