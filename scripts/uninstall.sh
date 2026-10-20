#!/usr/bin/env bash
# Removes MacGuard and all of its local data. Disarm protection first (the app asks for owner authentication on quit).
set -euo pipefail
osascript -e 'quit app "MacGuard"' 2>/dev/null || true
rm -rf /Applications/MacGuard.app
rm -rf "$HOME/Library/Application Support/MacGuard"
defaults delete com.harprosad.macguard 2>/dev/null || true
rm -f "$HOME/Library/Preferences/com.harprosad.macguard.plist"
security delete-generic-password -s com.harprosad.macguard -a installation-secret 2>/dev/null || true
security delete-generic-password -s com.harprosad.macguard -a installation-id 2>/dev/null || true
echo "Removed. Also remove MacGuard from System Settings → General → Login Items and → Privacy & Security → Location Services if listed."
