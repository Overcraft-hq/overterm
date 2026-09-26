#!/usr/bin/env bash
# Release notes for v<version>: the commits since the previous v* tag,
# grouped by their "area:" prefix — docs, test and CI commits left out, they
# change nothing you'd notice. The first release has no previous tag and a
# hundred commits of history; it gets the README's "What's in it" instead.
# Usage: Scripts/release-notes.sh <version> [dmg]
set -euo pipefail

VERSION="${1:?usage: release-notes.sh <version> [dmg]}"
DMG="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PREVIOUS="$(git describe --tags --abbrev=0 --match 'v*' HEAD 2>/dev/null || true)"
RANGE="${PREVIOUS:+$PREVIOUS..}HEAD"

echo "## Terminus ${VERSION}"
echo
if [[ -z "$PREVIOUS" ]]; then
  echo "The first release."
  echo
  echo "### What's in it"
  echo
  # The README section, up to the next heading.
  awk '/^## What.s in it/ { on = 1; next } /^## / { on = 0 } on' README.md | sed '/./,$!d'
else
  echo "Changes since ${PREVIOUS}."
  echo
  # "area: what changed" → grouped under the area, in the order areas first appear.
  git log --reverse --no-merges --format='%s' "$RANGE" | { grep -viE 'rails' || true; } | awk '
  {
    split($0, parts, ": ")
    area = (index($0, ": ") > 0) ? parts[1] : "other"
    text = (index($0, ": ") > 0) ? substr($0, length(area) + 3) : $0
    if (area ~ /^(docs|tests?|e2e|ci)$/) next
    if (!(area in seen)) { seen[area] = 1; order[++n] = area }
    items[area] = items[area] "- " text "\n"
  }
  END {
    if (n == 0) print "No user-facing changes."
    for (i = 1; i <= n; i++) { printf "### %s\n\n%s\n", order[i], items[order[i]] }
  }'
fi

cat <<NOTES
### Install

1. Open \`Terminus-${VERSION}.dmg\` and drag **Terminus** to **Applications**.
2. The app isn't notarized. The first time, open it with right-click → **Open**
   (on macOS 15: System Settings → Privacy & Security → **Open Anyway**), or run
   \`xattr -dr com.apple.quarantine /Applications/Terminus.app\`.

Apple Silicon, macOS 13 or later. Your \`~/.config/ghostty/config\` applies as-is.
NOTES

if [[ -n "$DMG" && -f "$DMG" ]]; then
  echo
  echo "SHA-256 \`$(basename "$DMG")\`: \`$(shasum -a 256 "$DMG" | cut -d' ' -f1)\`"
fi
