#!/usr/bin/env bash
# Run the Swift Testing suites. Usage: scripts/test.sh [extra swift test args]
# Command Line Tools ship the Testing framework but SwiftPM does not find its
# macro plugin on its own, so the plugin path is passed explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS="$(xcrun --find swiftc | sed 's|/usr/bin/swiftc$||')/usr/lib/swift/host/plugins/testing"
echo "==> swift test"
swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" ${@+"$@"}
