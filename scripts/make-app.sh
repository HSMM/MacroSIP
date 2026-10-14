#!/usr/bin/env bash
# Bundle the SwiftPM executable into a signed .app.
# Usage: scripts/make-app.sh [debug|release]   (produces dist/MacroSIP.app)
# A release app is universal (arm64 + x86_64); a debug app is native only, for speed.
# ARCHS="arm64" (or "x86_64", or "arm64 x86_64") overrides the architectures.
set -euo pipefail

CONFIG="${1:-release}"
NAME="MacroSIP"
BUNDLE_ID="com.hsmm.macrosip"
# In-app updates (ADR 0013): the appcast on the gh-pages branch and the public half of the EdDSA key
# whose private half signs every update (GitHub secret SPARKLE_PRIVATE_KEY; the owner's keychain).
FEED_URL="https://raw.githubusercontent.com/HSMM/MacroSIP/gh-pages/appcast.xml"
SPARKLE_PUBLIC_KEY="Ep5awGimvVdaDXffFrogCf7zb+Mtetuxs21pQhQV4Nk="
SIGN_IDENTITY="-"       # ad hoc
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
case "$CONFIG" in
  debug|release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

# Version: the nearest tag (26.0.0, see ADR 0010); before the first tag, Product.version from Product.swift.
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
[ -n "$VERSION" ] || VERSION="$(sed -n 's/.*static let fallbackVersion = "\([^"]*\)".*/\1/p' "$ROOT/Sources/MacroSIPCore/Product.swift")"
[ -n "$VERSION" ] || VERSION="0.0.0"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

# Universal builds need the universal archives from scripts/build-pjsip.sh.
if [ -n "${ARCHS:-}" ]; then
  read -r -a ARCH_LIST <<< "$ARCHS"
elif [ "$CONFIG" = release ]; then
  ARCH_LIST=(arm64 x86_64)
else
  ARCH_LIST=()          # native
fi
ARCH_FLAGS=()
for a in ${ARCH_LIST[@]+"${ARCH_LIST[@]}"}; do ARCH_FLAGS+=(--arch "$a"); done

echo "==> swift build ($CONFIG${ARCH_LIST[*]+, ${ARCH_LIST[*]}})"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product MacroSIPApp
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BUILT_ARCHS="$(lipo -archs "$BIN_DIR/MacroSIPApp")"
for a in ${ARCH_LIST[@]+"${ARCH_LIST[@]}"}; do
  case " $BUILT_ARCHS " in
    *" $a "*) ;;
    *) echo "error: $BIN_DIR/MacroSIPApp lacks the $a slice (has: $BUILT_ARCHS)" >&2; exit 1 ;;
  esac
done
echo "    architectures: $BUILT_ARCHS"

APP="$ROOT/dist/$NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacroSIPApp" "$APP/Contents/MacOS/$NAME"
# The linker also records @loader_path, the build directory and the Command Line Tools' Swift
# libraries as rpaths; the shipped binary keeps only the system Swift runtime and
# @executable_path/../Frameworks (Package.swift), so nothing outside the bundle and the OS is searched.
otool -l "$APP/Contents/MacOS/$NAME" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | sort -u |
  while read -r rp; do
    case "$rp" in
      /usr/lib/swift|@executable_path/../Frameworks) ;;
      *) while install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/$NAME" 2>/dev/null; do :; done ;;
    esac
  done
if otool -L "$APP/Contents/MacOS/$NAME" | grep '@rpath/' | grep -v '@rpath/Sparkle.framework/'; then
  echo "error: the binary needs @rpath libraries other than Sparkle (see above)" >&2; exit 1
fi

# Sparkle.framework (prebuilt by the Sparkle project, arm64 + x86_64) into Contents/Frameworks.
SPARKLE="$BIN_DIR/Sparkle.framework"
[ -d "$SPARKLE" ] || { echo "error: $SPARKLE not found (swift package resolve?)" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_ARCHS="$(lipo -archs "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle")"
for a in $BUILT_ARCHS; do
  case " $SPARKLE_ARCHS " in
    *" $a "*) ;;
    *) echo "error: Sparkle.framework lacks the $a slice (has: $SPARKLE_ARCHS)" >&2; exit 1 ;;
  esac
done

# Localizable.strings / .stringsdict go straight into Contents/Resources/<lang>.lproj, where
# Bundle.main finds them like in any macOS app (no dependency on SwiftPM's resource bundle, whose
# minimal Info.plist is not accepted by Bundle(url:) on every macOS release).
for lproj in "$ROOT"/Sources/MacroSIPApp/Resources/*.lproj; do
  mkdir -p "$APP/Contents/Resources/$(basename "$lproj")"
  cp "$lproj"/Localizable.* "$APP/Contents/Resources/$(basename "$lproj")/"
done
# Localized Info.plist strings (microphone prompt) for en and ru.
for lproj in "$ROOT"/packaging/InfoPlist/*.lproj; do
  mkdir -p "$APP/Contents/Resources/$(basename "$lproj")"
  cp "$lproj"/* "$APP/Contents/Resources/$(basename "$lproj")/"
done
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
  <key>NSContactsUsageDescription</key>
  <string>$NAME looks up names and numbers in Contacts when you search from the number field.</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>SIP address</string>
      <key>CFBundleURLSchemes</key>
      <array><string>sip</string><string>sips</string><string>tel</string></array>
    </dict>
  </array>
  <key>CFBundleLocalizations</key>
  <array><string>en</string><string>ru</string><string>be</string><string>uk</string><string>pl</string><string>de</string><string>fr</string><string>it</string><string>es</string><string>hi</string><string>zh-Hans</string></array>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST

echo "==> codesign (ad hoc, hardened runtime)"
# Hardened runtime everywhere. An ad hoc signature has no Team ID, so library validation would refuse
# the embedded Sparkle.framework; packaging/Entitlements.plist therefore carries
# com.apple.security.cs.disable-library-validation until the app is signed with a Developer ID (ADR 0013).
sign() { codesign --force --sign "$SIGN_IDENTITY" --options runtime "$@" 2>&1 | grep -v 'replacing existing signature' || true; }
# Inside out, as Sparkle documents for re-signing its framework: XPC services, Autoupdate, Updater.app,
# then the framework itself, then the app (no --deep: every nested item is signed explicitly).
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$FW/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
sign "$FW/Autoupdate"
sign "$FW/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$ROOT/packaging/Entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> $APP"
