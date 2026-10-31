#!/usr/bin/env bash
# What a drawing's page runs, offline: Excalidraw, React and lz-string,
# bundled into Resources/notes/excalidraw (checked in; make-app.sh
# copies Resources/notes into the app). The versions are pinned in
# Scripts/excalidraw/package.json and every package's hash in its
# package-lock.json, which `npm ci` checks. Run again only to change a
# version: edit package.json, `npm install --package-lock-only` there, run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Scripts/excalidraw"
OUT="$ROOT/Resources/notes/excalidraw"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$SRC/package.json" "$SRC/package-lock.json" "$SRC/entry.js" "$SRC/build.mjs" "$WORK/"
(cd "$WORK" && npm ci --no-audit --no-fund --ignore-scripts --silent && node build.mjs draw.js)

PKG="$WORK/node_modules/@excalidraw/excalidraw"
rm -rf "$OUT"
mkdir -p "$OUT/fonts" "$OUT/licenses"
cp "$WORK/draw.js" "$OUT/excalidraw.js"
cp "$PKG/dist/prod/index.css" "$OUT/excalidraw.css"
# Every font but Xiaolai (12 MB of Chinese): Excalidraw asks for them
# under EXCALIDRAW_ASSET_PATH/fonts/<family>/.
for dir in "$PKG/dist/prod/fonts"/*/; do
  family="$(basename "$dir")"
  [[ "$family" == Xiaolai ]] && continue
  cp -R "$dir" "$OUT/fonts/$family"
done
# Excalidraw's package ships no licence file; it is MIT (package.json).
printf 'Excalidraw %s — MIT License, https://github.com/excalidraw/excalidraw/blob/master/LICENSE\n' \
  "$(node -p "require('$PKG/package.json').version")" >"$OUT/licenses/excalidraw.txt"
cp "$WORK/node_modules/react/LICENSE" "$OUT/licenses/react.txt"
cp "$WORK/node_modules/lz-string/LICENSE" "$OUT/licenses/lz-string.txt"
echo "==> $OUT"
du -sh "$OUT"
