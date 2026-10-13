#!/usr/bin/env bash
# Add a release to the Sparkle appcast (ADR 0013) and write the result to <out-dir>/appcast.xml.
# Usage: scripts/make-appcast.sh <version> <dmg> <out-dir>
#        scripts/make-appcast.sh --check <version> <app>    only the checks below, before publishing
#   APPCAST_IN=<file>    the current appcast (from the gh-pages branch); its items are kept
#   NOTES_HTML=<file>    release notes as an HTML fragment, embedded in the new item
#   SPARKLE_PRIVATE_KEY  the EdDSA private key (CI secret); without it the key is read from the login
#                        keychain item that `generate_keys --account macrosip` created
# Versions are 26.1.0 or 26.1.0-rc.N (ADR 0010); anything else is refused. A version with a suffix
# goes to the "beta" channel, which the app offers only when Settings › General › Updates ›
# "Include release candidates" is on.
# Checks: the version format, and that the build number (CFBundleVersion, the commit count) is not
# already in the feed under another version — generate_appcast identifies items by build number, so a
# final release tagged on the same commit as its candidate would silently replace the candidate.
# Needs Sparkle's tools from the SwiftPM artifacts (swift build or swift package resolve first).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_URL="https://github.com/HSMM/MacroSIP"

valid_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$ ]] ||
    { echo "error: version '$1' is not N.N.N or N.N.N-rc.N" >&2; exit 1; }
}

# build_guard <version> <build> [appcast]: refuse a build number the feed has under another version.
build_guard() {
  python3 -I - "$1" "$2" "${3:-}" <<'PY'
import os, sys, xml.etree.ElementTree as ET
version, build, feed = sys.argv[1:]
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
if feed and os.path.exists(feed) and os.path.getsize(feed) > 0:
    for item in ET.parse(feed).getroot().findall("./channel/item"):
        other = item.findtext(f"{SP}shortVersionString")
        if item.findtext(f"{SP}version") == build and other != version:
            sys.exit(f"error: {version} has build {build} like the published {other}; "
                     "tag the release on a later commit (see docs/DEVELOPMENT.md, Releasing)")
print(f"    {version} (build {build}): not in the feed under another version")
PY
}

if [ "${1:-}" = "--check" ]; then
  [ $# -eq 3 ] || { echo "usage: $0 --check <version> <app>" >&2; exit 2; }
  valid_version "$2"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$3/Contents/Info.plist")"
  build_guard "$2" "$BUILD" "${APPCAST_IN:-}"
  exit 0
fi

[ $# -eq 3 ] || { echo "usage: $0 <version> <dmg> <out-dir>" >&2; exit 2; }
VERSION="$1"; DMG="$2"; OUT="$3"
valid_version "$VERSION"

GENERATE="$(find "$ROOT/.build/artifacts" -type f -path '*/Sparkle/bin/generate_appcast' 2>/dev/null | head -n 1)"
[ -x "$GENERATE" ] || { echo "error: generate_appcast not found; run swift package resolve first" >&2; exit 1; }
[ -f "$DMG" ] || { echo "error: $DMG not found" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macrosip-appcast.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# generate_appcast works on a directory: the existing feed plus the new archive and its notes.
BASE="MacroSIP-$VERSION"
cp "$DMG" "$WORK/$BASE.dmg"
if [ -n "${APPCAST_IN:-}" ] && [ -s "$APPCAST_IN" ]; then
  cp "$APPCAST_IN" "$WORK/appcast.xml"
fi
if [ -n "${NOTES_HTML:-}" ] && [ -s "$NOTES_HTML" ]; then
  cp "$NOTES_HTML" "$WORK/$BASE.html"
fi

flags=(
  --download-url-prefix "$REPO_URL/releases/download/$VERSION/"
  --link "$REPO_URL"
  --embed-release-notes
  --maximum-versions 0          # keep every published item: older ones have no archive here
  --maximum-deltas 0            # full DMGs only
)
CHANNEL_NOTE=""
case "$VERSION" in
  *-*) flags+=(--channel beta); CHANNEL_NOTE=" (channel beta)" ;;
esac

echo "==> generate_appcast $VERSION$CHANNEL_NOTE"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE" --ed-key-file - "${flags[@]}" "$WORK"
else
  "$GENERATE" --account macrosip "${flags[@]}" "$WORK"
fi

# The new item must be there once, signed, pointing at the release asset, with a build number that
# the feed did not have under another version.
python3 -I - "$WORK/appcast.xml" "$VERSION" "$REPO_URL/releases/download/$VERSION/$BASE.dmg" <<'PY'
import sys, xml.etree.ElementTree as ET
path, version, url = sys.argv[1:]
SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(path).getroot().findall("./channel/item")
new = [i for i in items if i.findtext(f"{SP}shortVersionString") == version]
if len(new) != 1:
    sys.exit(f"error: appcast has {len(new)} items for {version}")
enc = new[0].find("enclosure")
if enc is None or enc.get("url") != url or not enc.get(f"{SP}edSignature"):
    sys.exit(f"error: the {version} item has no signed enclosure at {url}")
print(f"    {len(items)} item(s); {version} (build {new[0].findtext(f'{SP}version')}) -> {url}")
open(path + ".build", "w").write(new[0].findtext(f"{SP}version") or "")
PY
build_guard "$VERSION" "$(cat "$WORK/appcast.xml.build")" "${APPCAST_IN:-}"

mkdir -p "$OUT"
cp "$WORK/appcast.xml" "$OUT/appcast.xml"
echo "==> $OUT/appcast.xml"
