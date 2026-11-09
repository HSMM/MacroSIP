#!/usr/bin/env bash
# Run the Swift Testing suites. Usage: scripts/test.sh [extra swift test args]
# Command Line Tools ship the Testing framework but SwiftPM does not find its
# macro plugin on its own, so the plugin path is passed explicitly. Newer Command
# Line Tools (26.4, Swift 6.3) do not find the Testing module either: when a probe
# compile cannot import it and the toolchain has Testing.framework, the framework
# and its interop library are passed too (search paths and rpaths). Xcode
# toolchains keep the framework elsewhere and are left as they are.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLCHAIN="$(xcrun --find swiftc | sed 's|/usr/bin/swiftc$||')"
PLUGINS="$TOOLCHAIN/usr/lib/swift/host/plugins/testing"
EXTRA=()
FRAMEWORKS="$TOOLCHAIN/Library/Developer/Frameworks"
if [ -d "$FRAMEWORKS/Testing.framework" ]; then
  PROBE="$(mktemp -d)"
  echo 'import Testing' > "$PROBE/probe.swift"
  if ! xcrun swiftc -typecheck "$PROBE/probe.swift" >/dev/null 2>&1; then
    echo "==> Testing module not found by default; using $FRAMEWORKS"
    EXTRA=(-Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"
           -Xlinker -rpath -Xlinker "$FRAMEWORKS")
    INTEROP="$TOOLCHAIN/Library/Developer/usr/lib"
    if [ -d "$INTEROP" ]; then EXTRA+=(-Xlinker -rpath -Xlinker "$INTEROP"); fi
  fi
  rm -rf "${PROBE:?}"
fi
echo "==> swift test"
swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" ${EXTRA[@]+"${EXTRA[@]}"} ${@+"$@"}
