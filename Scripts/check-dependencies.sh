#!/usr/bin/env bash
# Have the dependencies pinned in this repository moved on? For each one with a
# release newer than its pin, open an issue (once per release) with what the
# bump involves — the bump itself is by hand.
#
# - The notes' reading view (Scripts/fetch-notes-web.sh): markdown-it, its
#   footnotes, DOMPurify, KaTeX, highlight.js, mermaid. DOMPurify sanitises
#   every note's HTML: its releases are often security fixes.
# - Excalidraw's bundle (Scripts/excalidraw/package.json): Excalidraw and
#   esbuild. React and lz-string follow what Excalidraw asks for.
# - The Swift packages Package.swift names (the database drivers, SwiftNIO and
#   NIO SSL, swift-log, swift-crypto), against Package.resolved's pins — the
#   ones they bring in move with them. Dependabot can't: Package.swift names
#   GhosttyKit and TreeSitterKit, built here and never committed, and SwiftPM
#   won't resolve a graph without them.
#
# Ghostty has a check of its own (Scripts/check-ghostty-release.sh).
# Run weekly by .github/workflows/dependency-check.yml.
#
#   DRY_RUN=1 ./Scripts/check-dependencies.sh   # print, don't open
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-Overcraft-hq/overterm}"
NOTES="$ROOT/Scripts/fetch-notes-web.sh"
EXCALIDRAW="$ROOT/Scripts/excalidraw/package.json"
RESOLVED="$ROOT/Package.resolved"
SWIFT_PACKAGES="postgres-nio mysql-nio swift-nio swift-nio-ssl swift-log swift-crypto"

# kind|name|where to ask|pinned version|where it is pinned
pins=()
while IFS='|' read -r name path _; do
  pins+=("notes|$name|${path%%/-/*}|${path##*-}|Scripts/fetch-notes-web.sh")
done < <(sed -n 's/^  "\([^"]*\)".*$/\1/p' "$NOTES")
for package in "@excalidraw/excalidraw" "esbuild"; do
  version="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print({**d.get('dependencies',{}), **d.get('devDependencies',{})}[sys.argv[2]])" "$EXCALIDRAW" "$package")"
  pins+=("excalidraw|$package|$package|$version|Scripts/excalidraw/package.json")
done
while IFS='|' read -r identity location version; do
  pins+=("swift|$identity|$location|$version|Package.resolved")
done < <(python3 -c "
import json, sys
wanted = sys.argv[2].split()
for pin in json.load(open(sys.argv[1]))['pins']:
    if pin['identity'] in wanted and pin['state'].get('version'):
        print('|'.join([pin['identity'], pin['location'], pin['state']['version']]))
" "$RESOLVED" "$SWIFT_PACKAGES")

newer() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" != "$1" ]]; }

# The newest release: npm's `latest`, or a repository's highest X.Y.Z tag.
latest_of() {
  local kind="$1" source="$2"
  if [[ "$kind" == "swift" ]]; then
    git ls-remote --tags --refs "$source" | awk '{print $2}' | sed 's#refs/tags/##; s/^v//' |
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
  else
    curl -fsSL "https://registry.npmjs.org/$source/latest" | python3 -c "import json,sys; print(json.load(sys.stdin)['version'])"
  fi
}

status=0
for pin in "${pins[@]}"; do
  IFS='|' read -r kind name source pinned file <<<"$pin"
  if ! latest="$(latest_of "$kind" "$source")" || [[ -z "$latest" ]]; then
    echo "error: couldn't find $name's latest release ($source)" >&2
    status=1
    continue
  fi
  if ! newer "$pinned" "$latest"; then
    echo "up to date: $name $pinned (latest $latest)"
    continue
  fi

  major=""
  if [[ "${pinned%%.*}" != "${latest%%.*}" ]]; then major=" A major version: read what it changed before anything else."; fi
  title="$name $latest is out (pinned to $pinned)"
  if [[ "$name" == "dompurify" ]]; then title="$title — sanitises the notes' HTML"; fi

  case "$kind" in
    notes)
      where="is on npm. Overterm bundles **$pinned** (\`$file\`)."
      releases="https://www.npmjs.com/package/$source?activeTab=versions (its repository's release notes are linked from there)"
      steps="1. \`$file\`: the \`$name\` line's path to \`…-$latest\`, and its sha256 — \`curl -sfL https://registry.npmjs.org/$source/-/${source##*/}-$latest.tgz | shasum -a 256\`
2. \`Scripts/fetch-notes-web.sh\` — it rebuilds \`Resources/notes/vendor\` (checked in)
3. \`make test && make e2e\` (the notes, reading view and graph scenarios); a note with math, code, a mermaid diagram and footnotes, read by hand"
      ;;
    excalidraw)
      where="is on npm. Overterm bundles **$pinned** (\`$file\`)."
      releases="https://www.npmjs.com/package/$source?activeTab=versions (its repository's release notes are linked from there)"
      # An if, not `[[ … ]] && echo` inside $(…): for esbuild that substitution
      # fails, and under set -e the assignment ended the whole run silently.
      react=""
      if [[ "$source" == "@excalidraw/excalidraw" ]]; then
        react=" — and React to what its peerDependencies ask (\`npm view @excalidraw/excalidraw@$latest peerDependencies\`)"
      fi
      steps="1. \`$file\`: \`\"$source\": \"$latest\"\`$react
2. \`npm install --package-lock-only --ignore-scripts\` in \`Scripts/excalidraw\`, then \`Scripts/fetch-excalidraw.sh\` — it rebuilds \`Resources/notes/excalidraw\` (checked in)
3. \`make test && make e2e\` (the drawing scenario); draw by hand, and open a drawing made in Obsidian — the file format is the plugin's"
      ;;
    swift)
      where="is tagged. Overterm resolves **$pinned** (\`$file\`)."
      # A release for a newer Swift than the one releases are built with
      # (Package.swift's tools version: Xcode 16.4, Swift 6.1) can't be taken
      # until that moves — said up front, not found by trying.
      ours="$(sed -n '1s/.*swift-tools-version: *\([0-9.]*\).*/\1/p' "$ROOT/Package.swift")"
      theirs="$(curl -fsSL "${source%.git}/raw/$latest/Package.swift" 2>/dev/null | sed -n '1s/.*swift-tools-version: *\([0-9.]*\).*/\1/p' || true)"
      if [[ -n "$theirs" && -n "$ours" ]] && newer "$ours" "$theirs"; then
        title="$title — needs Swift $theirs"
        where="$where It needs **swift-tools-version $theirs**; Overterm builds with Swift $ours (Xcode 16.4), so it waits for the move to a newer Xcode."
      fi
      releases="${source%.git}/releases"
      steps="1. \`swift package update $name\` — it moves \`Package.resolved\` (and what $name brings in); raise its \`from:\` in \`Package.swift\` only if something needs the new version
2. \`make test && make e2e\`; for the database drivers and SwiftNIO also their tests against real servers: \`Scripts/database-test-servers.sh\`, then \`OVERTERM_DB_TESTS=1 make test\`
3. Docker's engine client runs on SwiftNIO too: the docker scenarios in \`make e2e\` cover it"
      ;;
  esac

  body="$(cat <<MD
**$name $latest** $where$major

- Releases: $releases

To bump:
$steps
4. \`Scripts/fetch-licenses.sh\` — About ▸ Acknowledgements lists the new version, its licence as it now reads (\`AcknowledgementsTests\` fails until then)
5. A commit of its own, in a version not yet released (\`Scripts/bump-version.sh patch\` if none is under way)

_Opened by the weekly dependency check._
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
