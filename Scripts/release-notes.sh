#!/usr/bin/env bash
# Release notes for a version: its CHANGELOG.md entry (the source of truth
# for what a version changed — CLAUDE.md, Commits), how to install, and the
# DMG's checksum. Fails when the changelog has no entry for the version.
# Usage: Scripts/release-notes.sh [version] [dmg]   (version: VERSION's)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(tr -d '[:space:]' <"$ROOT/VERSION")}"
DMG="${2:-}"

# "## 1.11.0 — 2026-09-26" up to the next "## ".
entry="$(awk -v v="$VERSION" '
  $0 ~ "^## " { if (on) exit; if ($2 == v) { on = 1; next } }
  on' "$ROOT/CHANGELOG.md" | sed '/./,$!d')"
if [[ -z "$entry" ]]; then
  echo "error: CHANGELOG.md has no entry for $VERSION" >&2
  exit 1
fi

cat <<NOTES
## Terminus ${VERSION}

${entry}

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
