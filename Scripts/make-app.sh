#!/usr/bin/env bash
# Assemble Overterm.app from the SPM release build and ad-hoc sign it.
set -euo pipefail

APP_NAME="Overterm"
# The SPM target, which keeps the old name (Package.swift).
PRODUCT="Terminus"
# Where the settings, the session and the privacy grants live. It is not
# the app's name and never was; renaming it would open a new, empty app.
BUNDLE_ID="io.github.terminus-app.terminus"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# What About Overterm shows (docs/architecture.md, Build metadata): the
# version from VERSION, the commit count as the build number (monotonic on
# main), the commit — "-dirty" with uncommitted changes — and the day.
# VERSION and BUILD in the environment override; without git, build 1 and
# commit "unknown".
if [[ -z "${VERSION:-}" ]]; then
  if [[ ! -f "$ROOT/VERSION" ]]; then
    echo "error: $ROOT/VERSION missing" >&2
    exit 1
  fi
  VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
fi
if git -C "$ROOT" rev-parse -q --verify HEAD >/dev/null 2>&1; then
  BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD)}"
  COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then COMMIT="$COMMIT-dirty"; fi
else
  BUILD="${BUILD:-1}"
  COMMIT="unknown"
fi
BUILD_DATE="$(date +%Y-%m-%d)"
echo "==> Overterm $VERSION ($BUILD), commit $COMMIT, $BUILD_DATE"

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${PRODUCT}"
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
# Beside Ghostty's own themes, where `theme = "<name>"` finds them and
# Settings ▸ Themes reads them (Scripts/fetch-themes.sh).
cp "$ROOT"/Resources/themes/* "$CONTENTS/Resources/ghostty/themes/"
rm -f "$CONTENTS/Resources/ghostty/themes/LICENSE" "$CONTENTS/Resources/ghostty/themes/README.md"
cp "$ROOT/Resources/themes/LICENSE" "$CONTENTS/Resources/THEMES-LICENSE"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
# Settings ▸ About shows this version's entry; View Latest Changelog, all of it.
cp "$ROOT/CHANGELOG.md" "$CONTENTS/Resources/CHANGELOG.md"

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
    <!-- About Overterm's credits (AboutPanel): the commit built, and when.
         The keys keep the old name; the About panel reads them by it. -->
    <key>TerminusCommit</key>
    <string>${COMMIT}</string>
    <key>TerminusBuildDate</key>
    <string>${BUILD_DATE}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Overterm</string>
    <!-- macOS charges what a program in the terminal asks for to Overterm,
         and without a reason here refuses it without asking: Claude Code's
         /voice got no microphone. Worded as Ghostty's. -->
    <key>NSMicrophoneUsageDescription</key>
    <string>A program running within ${APP_NAME} would like to use your microphone.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>A program running within ${APP_NAME} would like to use speech recognition.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>A program running within ${APP_NAME} would like to access your system's audio.</string>
    <!-- Finder's Open With and the Dock icon: a folder opens as a tab, a
         file in the editor. Alternate rank: listed, never the default. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.folder</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>File</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.text</string>
                <string>public.plain-text</string>
                <string>public.source-code</string>
                <string>public.script</string>
                <string>public.json</string>
                <string>public.yaml</string>
                <string>public.xml</string>
                <string>net.daringfireball.markdown</string>
                <string>public.data</string>
                <string>public.item</string>
            </array>
        </dict>
    </array>
    <!-- Finder's right-click > Services / Quick Actions. NSRequiredContext
         makes it on by default. Handled by AppDelegate.newTabHere. -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key>
            <dict><key>default</key><string>New Overterm Tab Here</string></dict>
            <key>NSMessage</key>
            <string>newTabHere</string>
            <key>NSPortName</key>
            <string>${APP_NAME}</string>
            <key>NSRequiredContext</key>
            <dict/>
            <key>NSSendFileTypes</key>
            <array><string>public.folder</string><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_DIR"
echo "==> done: $APP_DIR"
