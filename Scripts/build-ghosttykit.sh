#!/usr/bin/env bash
# Build Frameworks/GhosttyKit.xcframework from a pinned Ghostty release.
#
# Why a release tag and not main: Ghostty main needs Xcode 26 / the macOS 26
# SDK; the v1.3.x line builds GhosttyKit with Xcode 16. We only take the
# library — Ghostty's own macOS app is not built.
set -euo pipefail

GHOSTTY_REPO="https://github.com/ghostty-org/ghostty.git"
GHOSTTY_REF="v1.3.1"
GHOSTTY_SHA="332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/ghostty"
OUT="$ROOT/Frameworks/GhosttyKit.xcframework"

if [[ ! -d "$SRC/.git" ]]; then
  echo "==> cloning Ghostty $GHOSTTY_REF"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$GHOSTTY_REF" "$GHOSTTY_REPO" "$SRC"
elif [[ "$(git -C "$SRC" rev-parse HEAD)" != "$GHOSTTY_SHA" ]]; then
  echo "==> moving Ghostty checkout to $GHOSTTY_REF"
  git -C "$SRC" fetch --quiet --depth 1 origin tag "$GHOSTTY_REF"
  git -C "$SRC" checkout --quiet "$GHOSTTY_REF"
fi

# A moved tag is a supply-chain surprise, not something to build through.
actual="$(git -C "$SRC" rev-parse HEAD)"
if [[ "$actual" != "$GHOSTTY_SHA" ]]; then
  echo "error: $GHOSTTY_REF resolves to $actual, expected $GHOSTTY_SHA" >&2
  exit 1
fi

echo "==> zig build (GhosttyKit, native arch, ReleaseFast)"
cd "$SRC"
mise exec -- zig build \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -Doptimize=ReleaseFast

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$OUT"
echo "==> done: $OUT"
