#!/usr/bin/env bash
# Bundle the SwiftPM executable into a signed .app.
# Usage: scripts/make-app.sh [debug|release]   (produces dist/MacroSIP.app)
set -euo pipefail

CONFIG="${1:-release}"
NAME="MacroSIP"
BUNDLE_ID="com.hsmm.macrosip"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
case "$CONFIG" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

# Version: the nearest tag (26.0.0, see ADR 0011); before the first tag, Product.version from Product.swift.
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="$(sed -n 's/.*static let version = "\([^"]*\)".*/\1/p' "$ROOT/Sources/MacroSIPCore/Product.swift")"
[ -n "$VERSION" ] || VERSION="0.0.0"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product MacroSIPApp
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacroSIPApp" "$APP/Contents/MacOS/$NAME"

# SwiftPM resource bundle MacroSIP_MacroSIPApp.bundle (Localizable.strings per language); Bundle.module finds it in Contents/Resources.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# Localized Info.plist strings (microphone prompt) for en and ru.
cp -R "$ROOT"/packaging/InfoPlist/*.lproj "$APP/Contents/Resources/"
if [ -f "$ROOT/packaging/AppIcon.icns" ]; then
  cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 HSMM</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>$NAME needs the microphone to make and receive calls.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>SIP address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>sip</string><string>sips</string><string>tel</string></array>
    </dict>
  </array>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>ru</string></array>
</dict>
</plist>
PLIST

echo "==> codesign (ad hoc)"
codesign --force --sign - --entitlements "$ROOT/packaging/Entitlements.plist" \
  --options runtime "$APP" 2>&1 | grep -v 'replacing existing signature' || true
codesign --verify --deep --strict "$APP"
echo "==> $APP"
