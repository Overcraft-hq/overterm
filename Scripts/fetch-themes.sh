#!/usr/bin/env bash
# Resources/themes: a few colour themes our pinned Ghostty does not ship.
#
# Ghostty bundles a snapshot of iTerm2-Color-Schemes — 463 themes in v1.3.1 —
# and upstream has kept going. Rather than take all 349 of the newer ones,
# THEMES below is a hand-picked list; add a name to it and run this again.
# Scripts/make-app.sh copies them into Contents/Resources/ghostty/themes,
# where `theme = "<name>"` finds them and Settings ▸ Themes draws them.
#
# Checked in, so a clone needs no network. The themes are MIT licensed
# (Resources/themes/LICENSE). Bump SCHEMES_SHA to refresh: a pinned commit
# is what keeps someone else's push out of our build.
set -euo pipefail

SCHEMES_REPO="mbadolato/iTerm2-Color-Schemes"
SCHEMES_SHA="21f281d0834846eef984f75774638e7d16bac068"

# Named for what they are, not for the mood of the week: an editor's theme
# people already know, or the half of a family Ghostty's snapshot left out.
THEMES=(
  "Claude Dark"               # this app's own kind of work, in its colours
  "Claude Light"
  "Everforest Dark Soft"      # Ghostty ships only Dark Hard and Light Med
  "Everforest Light Soft"
  "Noctis"
  "Noctis Lux"
  "Tailwind Dark"
  "Tailwind Light"
  "JetBrains Islands Dark"
  "Dracula+ High Contrast"
)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_THEMES="$ROOT/Frameworks/GhosttyResources/ghostty/themes"
OUT="$ROOT/Resources/themes"

if [[ ! -d "$GHOSTTY_THEMES" ]]; then
  echo "error: $GHOSTTY_THEMES missing — run: make ghosttykit" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# One connection, one request per theme, names URL-escaped — most have spaces.
# (The repository itself is hundreds of megabytes of screenshots; these files
# are a few hundred bytes each.)
python3 - "$SCHEMES_REPO" "$SCHEMES_SHA" "$OUT" "${THEMES[@]}" > "$work/curl.conf" <<'PY'
import sys, urllib.parse
from pathlib import Path

repo, sha, out, *names = sys.argv[1:]
for name in names:
    path = urllib.parse.quote(f"ghostty/{name}")
    print(f'url = "https://raw.githubusercontent.com/{repo}/{sha}/{path}"')
    print(f'output = "{Path(out) / name}"')
PY

echo "==> fetching ${#THEMES[@]} themes from $SCHEMES_REPO @ ${SCHEMES_SHA:0:7}"
rm -rf "$OUT"
mkdir -p "$OUT"
curl -fsS --retry 3 -K "$work/curl.conf"

for name in "${THEMES[@]}"; do
  # Ghostty's own copy would win over ours: the same name twice is a theme
  # the gallery shows and the terminal doesn't take.
  if [[ -e "$GHOSTTY_THEMES/$name" ]]; then
    echo "error: Ghostty already ships \"$name\" — drop it from THEMES" >&2
    exit 1
  fi
  # A download that lost its way (a rename upstream, a proxy's error page)
  # would leave something that isn't a theme.
  if ! grep -qE '^(background|foreground) *=' "$OUT/$name"; then
    echo "error: \"$name\" came back as something else than a theme" >&2
    exit 1
  fi
done

curl -fsSL --retry 3 "https://raw.githubusercontent.com/$SCHEMES_REPO/$SCHEMES_SHA/LICENSE" -o "$OUT/LICENSE"

cat > "$OUT/README.md" <<EOF
# Extra themes

Themes [iTerm2-Color-Schemes][src] has and our pinned Ghostty does not,
fetched by \`Scripts/fetch-themes.sh\` at commit \`${SCHEMES_SHA:0:7}\` and
bundled into \`Contents/Resources/ghostty/themes\` beside Ghostty's own.
MIT licensed — see LICENSE.

Don't edit these by hand; the next fetch overwrites them. Your own themes go
in \`~/.config/ghostty/themes\`, which Ghostty reads too and Settings ▸ Themes
lists under "Yours".

[src]: https://github.com/$SCHEMES_REPO
EOF

echo "==> $(ls "$OUT" | grep -cv -e '^LICENSE$' -e '^README.md$') themes in Resources/themes, beside Ghostty's $(ls "$GHOSTTY_THEMES" | wc -l | tr -d ' ')"
