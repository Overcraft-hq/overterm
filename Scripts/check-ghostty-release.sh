#!/usr/bin/env bash
# Is there a Ghostty release newer than the one GhosttyKit is pinned to?
# If so, open an issue (once per release) with what the bump involves.
#
# Ghostty publishes no GitHub Releases (only the nightly "tip"); releases
# are vX.Y.Z tags. Run weekly by .github/workflows/ghostty-release-check.yml.
#
#   DRY_RUN=1 ./Scripts/check-ghostty-release.sh   # print, don't open
#   PINNED_REF=v1.2.3 DRY_RUN=1 ...                # pretend an older pin
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-Overcraft-hq/overterm}"
UPSTREAM="ghostty-org/ghostty"

pinned="${PINNED_REF:-$(sed -n 's/^GHOSTTY_REF="\(.*\)"/\1/p' "$ROOT/Scripts/build-ghosttykit.sh")}"
pinned_zig="$(sed -n 's/^zig = "\(.*\)"/\1/p' "$ROOT/mise.toml")"
latest="$(git ls-remote --tags --refs "https://github.com/$UPSTREAM.git" 'refs/tags/v*' \
  | awk '{print $2}' | sed 's#refs/tags/##' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"

if [[ -z "$latest" ]]; then
  echo "error: no release tags found in $UPSTREAM" >&2
  exit 1
fi
# Newest of the two, by version order: if it's the pin, nothing to do.
if [[ "$(printf '%s\n%s\n' "$pinned" "$latest" | sort -V | tail -1)" == "$pinned" ]]; then
  echo "up to date: pinned $pinned, latest $latest"
  exit 0
fi

title="Ghostty $latest is out (GhosttyKit is pinned to $pinned)"
raw="https://raw.githubusercontent.com/$UPSTREAM/$latest"
zig="$(curl -fsSL "$raw/build.zig.zon" | sed -n 's/.*minimum_zig_version = "\(.*\)".*/\1/p' || true)"
xcode="$(curl -fsSL "$raw/HACKING.md" | grep -oE 'Xcode [0-9]+' | head -1 || true)"
sha="$(git ls-remote --tags "https://github.com/$UPSTREAM.git" "refs/tags/$latest^{}" | awk '{print $1}')"
[[ -n "$sha" ]] || sha="$(git ls-remote --tags "https://github.com/$UPSTREAM.git" "refs/tags/$latest" | awk '{print $1}')"
notes="https://ghostty.org/docs/install/release-notes/$(echo "${latest#v}" | tr . -)"
xcode_line=""
if [[ -n "$xcode" ]]; then
  xcode_line="- Ghostty's build docs at that tag mention **$xcode**; the pin was set on Xcode 16.4 because main needed Xcode 26. Check before bumping."
fi

body="$(cat <<MD
Ghostty **$latest** has been tagged. GhosttyKit is built from **$pinned** (\`Scripts/build-ghosttykit.sh\`).

- Release notes: $notes
- Changes: https://github.com/$UPSTREAM/compare/$pinned...$latest
- Zig required: **${zig:-unknown}** (pinned in \`mise.toml\`: $pinned_zig)
$xcode_line

To bump:
1. \`Scripts/build-ghosttykit.sh\`: \`GHOSTTY_REF="$latest"\`, \`GHOSTTY_SHA="$sha"\`
2. \`mise.toml\`: \`zig = "${zig:-?}"\` if it changed, then \`mise install\`
3. \`make ghosttykit\` — then diff \`Frameworks/GhosttyKit.xcframework/*/Headers/ghostty.h\` against the old one for API changes
4. \`make test && make e2e\`; glance at the Ghostty keybind table in docs/ghostty.md (new default bindings can swallow Overterm shortcuts)
5. \`make install\`, use it for a bit, commit

_Opened by the weekly Ghostty release check._
MD
)"

if [[ "${DRY_RUN:-}" == "1" ]]; then
  printf 'WOULD OPEN: %s\n\n%s\n' "$title" "$body"
  exit 0
fi

existing="$(gh issue list -R "$REPO" --state open --search "in:title \"Ghostty $latest is out\"" --json number -q '.[0].number // empty')"
if [[ -n "$existing" ]]; then
  echo "already open: #$existing ($title)"
  exit 0
fi
gh issue create -R "$REPO" --title "$title" --body "$body" --label dependencies
