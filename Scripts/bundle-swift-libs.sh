#!/usr/bin/env bash
# Put the Swift libraries the app's binary loads by @rpath into the bundle,
# and refuse a bundle that would not start.
#
# Usage: Scripts/bundle-swift-libs.sh <Overterm.app>   (before signing)
#
# Swift 6.2's toolchain (Xcode 26 and later) links back-deployment libraries
# — libswiftCompatibilitySpan.dylib — by @rpath. macOS 26 has them in the
# OS; macOS 13 to 15 don't, and an app that doesn't carry them is killed by
# dyld at launch ("Library not loaded: @rpath/libswiftCompatibilitySpan
# .dylib"). Xcode's app targets copy them; a SwiftPM build assembled by
# hand (make-app.sh) must. 1.6.2 shipped without it and opened on no Mac
# older than macOS 26, while CI — on macOS 27 — passed.
#
# Each @rpath library of the binary (and of what is copied, in turn) is
# looked up where the linker said — the binary's LC_RPATHs into the
# toolchain — and then in the selected toolchain's lib/swift-*/macosx;
# copied into Contents/Frameworks, with @executable_path/../Frameworks
# added to the binary's rpaths and the build machine's toolchain paths
# taken out (a Mac with that Xcode would otherwise load its copy instead).
# One not found is an error. A toolchain that links none (Xcode 16.4)
# leaves the bundle as it was.
set -euo pipefail

APP="${1:?usage: $0 <app bundle>}"
CONTENTS="$APP/Contents"
BIN="$CONTENTS/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$CONTENTS/Info.plist" 2>/dev/null || basename "$APP" .app)"
FRAMEWORKS="$CONTENTS/Frameworks"
[[ -x "$BIN" ]] || { echo "error: no executable at $BIN" >&2; exit 1; }

# The libraries a Mach-O file loads by @rpath, by name.
rpath_libs() { otool -L "$1" | awk 'NR > 1 && $1 ~ /^@rpath\// { sub(/^@rpath\//, "", $1); print $1 }'; }
# Its LC_RPATH entries.
rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/ { found = 1 } found && $1 == "path" { print $2; found = 0 }'; }

TOOLCHAIN_LIB="$(cd "$(dirname "$(xcrun -f swift)")/../lib" && pwd)"
SEARCH=()
while IFS= read -r dir; do
  [[ "$dir" == /* ]] && SEARCH+=("$dir")
done < <(rpaths "$BIN")
for dir in "$TOOLCHAIN_LIB"/swift-*/macosx; do [[ -d "$dir" ]] && SEARCH+=("$dir"); done

# A library already in the bundle, where the binary's rpaths reach.
in_bundle() { [[ -f "$FRAMEWORKS/$1" || -f "$CONTENTS/MacOS/$1" ]]; }

copied=0
queue=()
while IFS= read -r lib; do queue+=("$lib"); done < <(rpath_libs "$BIN")
while ((${#queue[@]})); do
  lib="${queue[0]}"
  queue=("${queue[@]:1}")
  in_bundle "$lib" && continue
  src=""
  for dir in "${SEARCH[@]+"${SEARCH[@]}"}"; do
    if [[ -f "$dir/$lib" ]]; then src="$dir/$lib"; break; fi
  done
  if [[ -z "$src" ]]; then
    # In the OS's dyld cache only on the macOS that has it: the bundle
    # must carry it for every older one, so not found is not good enough.
    echo "error: $BIN loads @rpath/$lib, found in none of: ${SEARCH[*]-(no search path)}" >&2
    echo "       the app would not start on a macOS without it in /usr/lib/swift" >&2
    exit 1
  fi
  mkdir -p "$FRAMEWORKS"
  cp "$src" "$FRAMEWORKS/$lib"
  chmod u+w "$FRAMEWORKS/$lib"
  echo "==> bundled $lib (from $src)"
  copied=$((copied + 1))
  while IFS= read -r next; do queue+=("$next"); done < <(rpath_libs "$FRAMEWORKS/$lib")
done

if ((copied)); then
  if ! rpaths "$BIN" | grep -qx '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$BIN"
  fi
  # The build machine's toolchain: nothing of it is looked up at run time.
  while IFS= read -r dir; do
    case "$dir" in
      /usr/lib/swift | @*) ;;
      *) install_name_tool -delete_rpath "$dir" "$BIN" ;;
    esac
  done < <(rpaths "$BIN")
fi

# The check that would have stopped 1.6.2: every @rpath library is in the
# bundle, under an rpath the binary has.
missing=0
for file in "$BIN" "$FRAMEWORKS"/*.dylib; do
  [[ -f "$file" ]] || continue
  while IFS= read -r lib; do
    if ! in_bundle "$lib"; then
      echo "error: $(basename "$file") loads @rpath/$lib, which the bundle doesn't carry" >&2
      missing=1
    fi
  done < <(rpath_libs "$file")
done
if ((copied)) && ! rpaths "$BIN" | grep -qx '@executable_path/../Frameworks'; then
  echo "error: $BIN has no @executable_path/../Frameworks rpath" >&2
  missing=1
fi
((missing == 0)) || exit 1
echo "==> Swift libraries: $copied bundled, every @rpath library in the bundle"
