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
  "markdown-it|markdown-it/-/markdown-it-14.1.0|7c4fab4d4d39fe98206a7fbbed4b1e3578f2b70b6b69d309413e33eec140e19f"
  "markdown-it-footnote|markdown-it-footnote/-/markdown-it-footnote-4.0.0|319e1c784b74a73b473e76a1bb725d3770c5a2e409dfd8c30c504f3a2712e272"
  "dompurify|dompurify/-/dompurify-3.1.7|2626fa6a51d2959df24633f11ee970fca72caac1a1c83ea87db927c7041742fc"
  "katex|katex/-/katex-0.16.11|8c5494c5f7d8e8bf73ff3fe64d4bd09a340e4878b7eec9bbd9ef8d8f3e24193f"
  "highlight.js|@highlightjs/cdn-assets/-/cdn-assets-11.10.0|5df5f63aad9acb3660d0d008cd68bdf5a6b7121816f517e2434d1e2f027b220f"
  "mermaid|mermaid/-/mermaid-11.4.1|ec7b61b391aaa24bf666fd20e48d0a626eeb4a95b95bc6b3016a122d7f0bc2af"
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
cp "$(P markdown-it)/dist/markdown-it.min.js" "$OUT/"
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
