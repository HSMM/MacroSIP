#!/usr/bin/env bash
# Release workflow helper (ADR 0013): put <version> into appcast.xml on the gh-pages branch and attach
# the new appcast.xml to the GitHub Release.
# Usage: scripts/publish-appcast.sh <version> <dmg>          (writes dist/appcast.xml, pushes gh-pages)
#        scripts/publish-appcast.sh --check <version> <app>  (make-appcast.sh --check against gh-pages)
#   NOTES_HTML, SPARKLE_PRIVATE_KEY: passed on to make-appcast.sh; GH_TOKEN: for `gh release upload`.
# Runs inside the repository checkout and pushes with its credentials (actions/checkout's auth
# header), never with a token in a URL. When another release pushed gh-pages first, the push is
# rejected and the whole step (fetch, generate, commit, push) is retried, so releases queue up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PAGES_REF="refs/remotes/origin/gh-pages"

# Sets PAGES_EXISTS; any git or network failure stops the script (no silent "branch missing").
fetch_pages() {
  local heads
  heads="$(git ls-remote --heads origin gh-pages)"
  if [ -n "$heads" ]; then
    git fetch --quiet --no-tags --depth 1 origin "+refs/heads/gh-pages:$PAGES_REF"
    PAGES_EXISTS=1
  else
    PAGES_EXISTS=0
  fi
}

# current_appcast <file>: the appcast on gh-pages, or an empty file before the first release.
current_appcast() {
  : > "$1"
  if [ "$PAGES_EXISTS" = 1 ] && git cat-file -e "$PAGES_REF:appcast.xml" 2>/dev/null; then
    git show "$PAGES_REF:appcast.xml" > "$1"
  fi
}

if [ "${1:-}" = "--check" ]; then
  [ $# -eq 3 ] || { echo "usage: $0 --check <version> <app>" >&2; exit 2; }
  fetch_pages
  FEED="$(mktemp "${TMPDIR:-/tmp}/macrosip-appcast.XXXXXX")"
  trap 'rm -f "$FEED"' EXIT
  current_appcast "$FEED"
  APPCAST_IN="$FEED" "$ROOT/scripts/make-appcast.sh" --check "$2" "$3"
  exit 0
fi

[ $# -eq 2 ] || { echo "usage: $0 <version> <dmg>" >&2; exit 2; }
VERSION="$1"; DMG="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
OUT="$ROOT/dist"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/macrosip-pages.XXXXXX")"
PAGES="$SCRATCH/gh-pages"
ORPHAN="appcast-orphan-$$"
cleanup() {
  git worktree remove --force "$PAGES" 2>/dev/null || true
  git branch -D "$ORPHAN" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

pushed=0
for attempt in 1 2 3 4 5; do
  fetch_pages
  if [ "$PAGES_EXISTS" = 1 ]; then
    git worktree add --quiet --detach "$PAGES" "$PAGES_REF"
  else
    echo "gh-pages does not exist yet; creating it"
    git worktree add --quiet --detach "$PAGES" HEAD
    git -C "$PAGES" checkout --quiet --orphan "$ORPHAN"
    git -C "$PAGES" rm -rfq .
    touch "$PAGES/.nojekyll"
    printf '%s\n' "# MacroSIP update feed" "" \
      "appcast.xml is the Sparkle feed of MacroSIP (ADR 0013), written by .github/workflows/release.yml." \
      > "$PAGES/README.md"
  fi

  APPCAST_IN="$PAGES/appcast.xml" "$ROOT/scripts/make-appcast.sh" "$VERSION" "$DMG" "$OUT"
  cp "$OUT/appcast.xml" "$PAGES/appcast.xml"
  git -C "$PAGES" add -A
  if git -C "$PAGES" diff --cached --quiet; then
    echo "appcast.xml on gh-pages already has $VERSION"
    pushed=1
  else
    git -C "$PAGES" -c user.name="github-actions[bot]" \
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      commit --quiet -m "Appcast: MacroSIP $VERSION"
    if git -C "$PAGES" push --quiet origin HEAD:refs/heads/gh-pages; then
      pushed=1
    fi
  fi
  cleanup
  mkdir -p "$SCRATCH"
  [ "$pushed" = 1 ] && break
  echo "gh-pages moved on (attempt $attempt); retrying"
  sleep $((attempt * 10))
done
[ "$pushed" = 1 ] || { echo "error: could not push gh-pages" >&2; exit 1; }

gh release upload "$VERSION" "$OUT/appcast.xml" --clobber
echo "feed: https://raw.githubusercontent.com/HSMM/MacroSIP/gh-pages/appcast.xml"
