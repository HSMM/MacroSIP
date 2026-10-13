#!/usr/bin/env bash
# Fill the version and the DMG checksum into the Homebrew cask template and write dist/macrosip.rb.
# Usage: scripts/update-cask.sh <version> <path-to-dmg>
#   TAP_DIR=/path/to/homebrew-tap scripts/update-cask.sh ...   also copies the cask to
#   Casks/macrosip.rb of that clone, commits "macrosip <version>" and pushes.
# Without TAP_DIR the git commands are only printed.
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <version> <dmg>" >&2; exit 2; }
VERSION="$1"
DMG="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$ROOT/packaging/homebrew/macrosip.rb"
OUT="$ROOT/dist/macrosip.rb"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?$ ]] || { echo "bad version: $VERSION" >&2; exit 2; }
[ -f "$DMG" ] || { echo "no such file: $DMG" >&2; exit 1; }

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
mkdir -p "$ROOT/dist"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" "$TEMPLATE" > "$OUT"
grep -q '@[A-Z0-9]*@' "$OUT" && { echo "placeholders left in $OUT" >&2; exit 1; }
echo "wrote $OUT (version $VERSION, sha256 $SHA)"

if [ -n "${TAP_DIR:-}" ]; then
  mkdir -p "$TAP_DIR/Casks"
  cp "$OUT" "$TAP_DIR/Casks/macrosip.rb"
  git -C "$TAP_DIR" add Casks/macrosip.rb
  if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "cask in $TAP_DIR already up to date"
  else
    git -C "$TAP_DIR" commit -m "macrosip $VERSION"
    git -C "$TAP_DIR" push
  fi
else
  cat <<MSG

To publish, in a clone of HSMM/homebrew-tap:
  cp "$OUT" Casks/macrosip.rb
  git add Casks/macrosip.rb
  git commit -m "macrosip $VERSION"
  git push
(or run this script again with TAP_DIR=<that clone>)
MSG
fi
