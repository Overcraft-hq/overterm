#!/usr/bin/env bash
# What a note's reading view runs, offline: markdown-it (and its footnotes),
# DOMPurify, KaTeX, highlight.js and mermaid — pinned, SHA-checked, from
# npm's registry, into Resources/notes/vendor (checked in; make-app.sh
# copies Resources/notes into the app). Run again only to change a version:
# bump it here with its new sha256.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/notes/vendor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# name|registry path|sha256
PACKAGES=(
  "markdown-it|markdown-it/-/markdown-it-15.0.3|98a7453983ab0e268c17dbd5260bf7190ba46b4cca912327fc1c1a2578e4b56d"
  "markdown-it-footnote|markdown-it-footnote/-/markdown-it-footnote-4.0.0|319e1c784b74a73b473e76a1bb725d3770c5a2e409dfd8c30c504f3a2712e272"
  "dompurify|dompurify/-/dompurify-3.4.17|056cbdae276897208b88c21d1d779adfa09ad7be488a2f510a28e900d3bbffe7"
  "katex|katex/-/katex-0.19.1|24da5a599eb2fcede2e270b99a6ff48bca816beecc95feeb84e8cccbd1bb34fd"
  "highlight.js|@highlightjs/cdn-assets/-/cdn-assets-11.12.0|b8a006d30f45afe783072569f3d69c5b60c0e7b9ca28cd474e12f2584e2a3bd9"
  "mermaid|mermaid/-/mermaid-12.2.0|071914164d0f6d53e5c26a10a220230d4ae8d37ed0f2263fbf072266f0af3a0a"
)

for entry in "${PACKAGES[@]}"; do
  IFS='|' read -r name path sha <<<"$entry"
  tarball="$WORK/$name.tgz"
  curl -sfL "https://registry.npmjs.org/$path.tgz" -o "$tarball"
  actual="$(shasum -a 256 "$tarball" | cut -c1-64)"
  if [[ "$actual" != "$sha" ]]; then
    echo "error: $name: sha256 $actual, expected $sha" >&2
    exit 1
  fi
  mkdir -p "$WORK/$name"
  tar xzf "$tarball" -C "$WORK/$name"
done

rm -rf "$OUT"
mkdir -p "$OUT/fonts" "$OUT/licenses"
P() { echo "$WORK/$1/package"; }
# markdown-it 15 ships its browser build as UMD under dist/browser; the
# reader loads it by the old name.
cp "$(P markdown-it)/dist/browser/markdown-it.umd.min.js" "$OUT/markdown-it.min.js"
cp "$(P markdown-it-footnote)/dist/markdown-it-footnote.min.js" "$OUT/"
cp "$(P dompurify)/dist/purify.min.js" "$OUT/"
cp "$(P katex)/dist/katex.min.js" "$(P katex)/dist/katex.min.css" "$OUT/"
cp "$(P katex)"/dist/fonts/*.woff2 "$OUT/fonts/"
cp "$(P highlight.js)/highlight.min.js" "$OUT/"
cp "$(P mermaid)/dist/mermaid.min.js" "$OUT/"
for name in markdown-it markdown-it-footnote dompurify katex highlight.js mermaid; do
  license="$(ls "$(P "$name")" | grep -i '^licen[cs]e' | head -1)"
  cp "$(P "$name")/$license" "$OUT/licenses/$name.txt"
done
echo "==> $OUT"
du -sh "$OUT"
