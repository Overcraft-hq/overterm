#!/usr/bin/env bash
# Have the web libraries bundled into the app moved on? For each one newer on
# npm than its pin, open an issue (once per release) with what the bump
# involves — the bump itself is by hand: a bundle is rebuilt and checked in.
#
# - The notes' reading view (Scripts/fetch-notes-web.sh): markdown-it, its
#   footnotes, DOMPurify, KaTeX, highlight.js, mermaid. DOMPurify sanitises
#   every note's HTML: its releases are often security fixes.
# - Excalidraw's bundle (Scripts/excalidraw/package.json): Excalidraw and
#   esbuild. React and lz-string follow what Excalidraw asks for.
#
# Run weekly by .github/workflows/web-release-check.yml.
#
#   DRY_RUN=1 ./Scripts/check-web-releases.sh   # print, don't open
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-Overcraft-hq/overterm}"
NOTES="$ROOT/Scripts/fetch-notes-web.sh"
EXCALIDRAW="$ROOT/Scripts/excalidraw/package.json"

# name|npm package|pinned version|where it is pinned|how to bump
pins=()
while IFS='|' read -r name path _; do
  package="${path%%/-/*}"
  version="${path##*-}"
  pins+=("$name|$package|$version|Scripts/fetch-notes-web.sh|notes")
done < <(sed -n 's/^  "\([^"]*\)".*$/\1/p' "$NOTES")
for package in "@excalidraw/excalidraw" "esbuild"; do
  version="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print({**d.get('dependencies',{}), **d.get('devDependencies',{})}[sys.argv[2]])" "$EXCALIDRAW" "$package")"
  pins+=("$package|$package|$version|Scripts/excalidraw/package.json|excalidraw")
done

newer() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" != "$1" ]]; }

status=0
for pin in "${pins[@]}"; do
  IFS='|' read -r name package pinned file kind <<<"$pin"
  latest="$(curl -fsSL "https://registry.npmjs.org/$package/latest" | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])")" || {
    echo "error: couldn't ask npm about $package" >&2
    status=1
    continue
  }
  if ! newer "$pinned" "$latest"; then
    echo "up to date: $name $pinned (latest $latest)"
    continue
  fi

  major=""
  if [[ "${pinned%%.*}" != "${latest%%.*}" ]]; then major=" A major version: read what it changed before anything else."; fi
  title="$name $latest is out (pinned to $pinned)"
  if [[ "$name" == "dompurify" ]]; then title="$title — sanitises the notes' HTML"; fi

  if [[ "$kind" == "notes" ]]; then
    steps="1. \`$file\`: the \`$name\` line's path to \`…-$latest\`, and its sha256 — \`curl -sfL https://registry.npmjs.org/$package/-/${package##*/}-$latest.tgz | shasum -a 256\`
2. \`Scripts/fetch-notes-web.sh\` — it rebuilds \`Resources/notes/vendor\` (checked in)
3. \`make test && make e2e\` (the notes, reading view and graph scenarios); a note with math, code, a mermaid diagram and footnotes, read by hand"
  else
    # An if, not `[[ … ]] && echo` inside $(…): for esbuild that substitution
    # fails, and under set -e the assignment ended the whole run silently.
    react=""
    if [[ "$package" == "@excalidraw/excalidraw" ]]; then
      react=" — and React to what its peerDependencies ask (\`npm view @excalidraw/excalidraw@$latest peerDependencies\`)"
    fi
    steps="1. \`$file\`: \`\"$package\": \"$latest\"\`$react
2. \`npm install --package-lock-only --ignore-scripts\` in \`Scripts/excalidraw\`, then \`Scripts/fetch-excalidraw.sh\` — it rebuilds \`Resources/notes/excalidraw\` (checked in)
3. \`make test && make e2e\` (the drawing scenario); draw by hand, and open a drawing made in Obsidian — the file format is the plugin's"
  fi

  body="$(cat <<MD
**$name $latest** is on npm. Overterm bundles **$pinned** (\`$file\`).$major

- Releases: https://www.npmjs.com/package/$package?activeTab=versions (its repository's release notes are linked from there)

To bump:
$steps
4. A commit of its own, with VERSION bumped (\`Scripts/bump-version.sh patch\`)

_Opened by the weekly web release check._
MD
)"

  if [[ "${DRY_RUN:-}" == "1" ]]; then
    printf 'WOULD OPEN: %s\n\n%s\n\n' "$title" "$body"
    continue
  fi
  existing="$(gh issue list -R "$REPO" --state open --search "in:title \"$name $latest is out\"" --json number -q '.[0].number // empty')"
  if [[ -n "$existing" ]]; then
    echo "already open: #$existing ($title)"
    continue
  fi
  gh issue create -R "$REPO" --title "$title" --body "$body" --label dependencies
done
exit $status
