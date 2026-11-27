#!/usr/bin/env bash
# Frameworks/DuckDBKit.xcframework: DuckDB's own library (libduckdb.dylib,
# MIT) as its release ships it, for the database client's DuckDB kind
# (DuckDBDriver). Not committed; `make duckdb`, as GhosttyKit is made.
#
# Why the release's library and not a Swift package: duckdb-swift's last
# release is 1.1.3 — a 2024 DuckDB that may not open a file today's `duckdb`
# wrote. The release's universal dylib is SHA-checked here, thinned to this
# Mac's architecture (the app is built for its own), its local symbols
# stripped (65 MB → 52 MB for arm64) and signed ad hoc again — strip breaks
# the signature, and macOS kills a process loading it unsigned (the tests'
# too). Its install name is @rpath/libduckdb.dylib: make-app.sh copies it
# into Contents/Frameworks, where the binary's rpath finds it.
#
# The C API is used, through `CDuckDB.h`, which allows its deprecated
# materialised-result calls (`duckdb_value_varchar`) — every value as text,
# the shape every driver gives.
#
# To bump: DUCKDB_VERSION and DUCKDB_SHA256 (the release's
# duckdb-shared-libs-osx-universal.tar.gz digest, on its release page), then
# Scripts/fetch-licenses.sh.
set -euo pipefail

DUCKDB_VERSION="2.0.1"
# Bumped when the xcframework's layout changes, so a cached one is made again.
DUCKDB_LAYOUT="2"
DUCKDB_SHA256="9a4be5a2a31ad5bb8c92bf37f18d59b9c10a79b392d7848cabd6eb2e05837449"
DUCKDB_URL="https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb-shared-libs-osx-universal.tar.gz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Frameworks/DuckDBKit.xcframework"
STAMP="$ROOT/Frameworks/DuckDBKit.version"
ARCH="${ARCH:-$(uname -m)}"

# Made already, from this version for this architecture: nothing to do.
if [[ -d "$OUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$DUCKDB_VERSION $ARCH $DUCKDB_LAYOUT" ]]; then
  echo "==> DuckDBKit $DUCKDB_VERSION ($ARCH) is there"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> fetching DuckDB $DUCKDB_VERSION"
for attempt in 1 2 3; do
  curl -fsSL --retry 2 -o "$WORK/duckdb.tar.gz" "$DUCKDB_URL" && break
  [[ $attempt == 3 ]] && { echo "error: couldn't fetch $DUCKDB_URL" >&2; exit 1; }
  sleep 5
done
actual="$(shasum -a 256 "$WORK/duckdb.tar.gz" | awk '{ print $1 }')"
if [[ "$actual" != "$DUCKDB_SHA256" ]]; then
  echo "error: $DUCKDB_URL has SHA-256 $actual, not the pinned $DUCKDB_SHA256" >&2
  exit 1
fi

mkdir -p "$WORK/unpacked" "$WORK/lib/include/CDuckDB"
tar -xzf "$WORK/duckdb.tar.gz" -C "$WORK/unpacked"
lipo "$WORK/unpacked/libduckdb.dylib" -thin "$ARCH" -output "$WORK/lib/libduckdb.dylib"
strip -x "$WORK/lib/libduckdb.dylib"
codesign --force --sign - "$WORK/lib/libduckdb.dylib"
[[ "$(otool -D "$WORK/lib/libduckdb.dylib" | tail -1)" == "@rpath/libduckdb.dylib" ]] || {
  echo "error: libduckdb.dylib's install name isn't @rpath/libduckdb.dylib" >&2
  exit 1
}

# In a folder of the module's name, as TreeSitterKit's: at the headers' top
# its module.modulemap and GhosttyKit's collided in Swift Build's include
# folder ("Multiple commands produce …/include/module.modulemap").
cp "$WORK/unpacked/duckdb.h" "$WORK/lib/include/CDuckDB/duckdb.h"
cat >"$WORK/lib/include/CDuckDB/CDuckDB.h" <<'EOF'
// The materialised result's calls (duckdb_value_varchar…) are deprecated,
// not gone: DuckDBDriver reads every value as text through them.
#define DUCKDB_API_ALLOW_DEPRECATED 1
#include "duckdb.h"
EOF
cat >"$WORK/lib/include/CDuckDB/module.modulemap" <<'EOF'
module CDuckDB {
    header "CDuckDB.h"
    export *
}
EOF

rm -rf "$OUT"
mkdir -p "$ROOT/Frameworks"
xcodebuild -create-xcframework -library "$WORK/lib/libduckdb.dylib" -headers "$WORK/lib/include" -output "$OUT" >/dev/null
echo "$DUCKDB_VERSION $ARCH $DUCKDB_LAYOUT" >"$STAMP"
echo "==> $OUT ($(du -sh "$OUT" | awk '{ print $1 }'), DuckDB $DUCKDB_VERSION, $ARCH)"
