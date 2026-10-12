#!/usr/bin/env bash
# Build the app and pack it into dist/MacroSIP-<version>.dmg (volume "MacroSIP", with an
# Applications symlink to drag the app onto). The app is signed ad hoc by make-app.sh.
# Usage: scripts/make-dmg.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
case "$CONFIG" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

"$ROOT/scripts/make-app.sh" "$CONFIG"

APP="$ROOT/dist/MacroSIP.app"
VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
DMG="$ROOT/dist/MacroSIP-$VERSION.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/macrosip-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging"
cp -R "$APP" "$STAGE/MacroSIP.app"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create"
rm -f "$DMG"
hdiutil create -volname "MacroSIP" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo "==> $DMG ($(du -h "$DMG" | awk '{print $1}'))"
echo "    sha256 $(shasum -a 256 "$DMG" | awk '{print $1}')"
