#!/usr/bin/env bash
# Runs the Swift tests. Works with Command Line Tools only (loads the Swift Testing macro plugin explicitly).
set -euo pipefail
cd "$(dirname "$0")/.."

PLUGIN="$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
[ -f "$PLUGIN" ] || PLUGIN="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$PLUGIN" ]; then swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN"; else swift test; fi
