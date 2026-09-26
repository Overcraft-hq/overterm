#!/usr/bin/env bash
# Package Terminus.app (built by make-app.sh) as dist/Terminus-<version>.dmg:
# the app and an Applications link, compressed. The version is VERSION's
# (the file), as make-app.sh's is; VERSION in the environment overrides.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-$(tr -d '[:space:]' <"$ROOT/VERSION")}"
APP="$ROOT/Terminus.app"
DMG="$ROOT/dist/Terminus-${VERSION}.dmg"

if [[ ! -d "$APP" ]]; then
  echo "error: $APP missing — run: make app" >&2
  exit 1
fi
built="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$built" != "$VERSION" ]]; then
  echo "error: Terminus.app is version $built, not $VERSION — run: VERSION=$VERSION make app" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$ROOT/dist"
rm -f "$DMG"
hdiutil create -quiet -volname "Terminus ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
