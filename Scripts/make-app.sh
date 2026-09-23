#!/usr/bin/env bash
# Assemble Terminus.app from the SPM release build and ad-hoc sign it.
set -euo pipefail

APP_NAME="Terminus"
BUNDLE_ID="ai.promptrails.terminus"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

APP_DIR="$ROOT/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_PATH" "$CONTENTS/MacOS/${APP_NAME}"

GHOSTTY_RES="$ROOT/Frameworks/GhosttyResources"
if [[ ! -d "$GHOSTTY_RES" ]]; then
  echo "error: $GHOSTTY_RES missing — run: make ghosttykit" >&2
  exit 1
fi
cp -R "$GHOSTTY_RES/." "$CONTENTS/Resources/"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Internal tool — PromptRails</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
echo "==> done: $APP_DIR"
