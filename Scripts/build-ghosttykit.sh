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
RES="$ROOT/Frameworks/GhosttyResources"

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

# Xcode 26 breaks v1.3.1's build twice — its SDK's stubs, which Zig can't
# link against, and its libtool, which drops what Zig archived
# (Scripts/ghosttykit-xcode26.py). With it, Zig gets a fixed copy of the
# SDK and libtool a fixed copy of each archive, by tools in front on PATH.
# CI's Xcode 16 needs none of it.
xcode_major="$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9]*\).*/\1/p')"
if [[ "${xcode_major:-0}" -ge 26 ]]; then
  echo "==> Xcode $xcode_major: an SDK and a libtool Zig 0.15.2 can work with"
  SHIMS="$ROOT/vendor/xcode26"
  rm -rf "$SHIMS"
  mkdir -p "$SHIMS/bin"
  python3 -I "$ROOT/Scripts/ghosttykit-xcode26.py" sdk "$(xcrun --sdk macosx --show-sdk-path)" "$SHIMS/MacOSX.sdk"
  cat > "$SHIMS/bin/xcrun" <<EOF
#!/bin/sh
# xcrun, with the macOS SDK's path the fixed copy's (ghosttykit-xcode26.py).
for arg in "\$@"; do [ "\$arg" = --show-sdk-path ] && { echo "$SHIMS/MacOSX.sdk"; exit 0; }; done
exec /usr/bin/xcrun "\$@"
EOF
  cat > "$SHIMS/bin/libtool" <<EOF
#!/bin/sh
exec python3 -I "$ROOT/Scripts/ghosttykit-xcode26.py" libtool "\$@"
EOF
  chmod +x "$SHIMS/bin/xcrun" "$SHIMS/bin/libtool"
  export PATH="$SHIMS/bin:$PATH"
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

# An archive that lost libghostty itself still "builds"; the app's link
# then fails on every ghostty_ symbol. A libtool run cached from before
# the fix above is one way to get it.
# (No grep -q: under pipefail, nm's SIGPIPE would fail the check.)
if ! nm -gU "$OUT"/*/libghostty*.a 2>/dev/null | grep " T _ghostty_app_new$" >/dev/null; then
  echo "error: $OUT has no ghostty_app_new — rm -rf vendor/ghostty/.zig-cache and build again" >&2
  exit 1
fi

# Runtime resources libghostty looks for next to the executable, in
# Contents/Resources: terminfo (its sentinel for finding the dir, and what makes
# TERM=xterm-ghostty work) and ghostty/ (shell integration, themes). Without
# them the shell gets xterm-256color and no shell integration.
rm -rf "$RES"
mkdir -p "$RES"
cp -R "$SRC/zig-out/share/ghostty" "$SRC/zig-out/share/terminfo" "$RES/"
echo "==> done: $OUT, $RES"
