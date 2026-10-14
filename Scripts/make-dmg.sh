#!/usr/bin/env bash
# Package Overterm.app (built by make-app.sh) as dist/Overterm-<version>.dmg:
# the app and an Applications link, compressed. The version is VERSION's
# (the file), as make-app.sh's is; VERSION in the environment overrides.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(tr -d '[:space:]' <"$ROOT/VERSION")}"
APP="$ROOT/Overterm.app"
DMG="$ROOT/dist/Overterm-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP missing — run: make app" >&2
  exit 1
fi
built="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$built" != "$VERSION" ]]; then
  echo "error: Overterm.app is version $built, not $VERSION — run: VERSION=$VERSION make app" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/dist"
rm -f "$DMG"
hdiutil create -quiet -volname "Overterm ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
