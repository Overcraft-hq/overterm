#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from Resources/AppIcon.png (1024×1024,
# the icon as drawn: the rounded tile is part of the artwork, and sips
# keeps the transparent corners outside it).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Resources/AppIcon.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns "$ICONSET" --output "$ROOT/Resources/AppIcon.icns"
echo "==> done: Resources/AppIcon.icns"
