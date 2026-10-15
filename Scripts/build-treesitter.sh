#!/usr/bin/env bash
# Build Frameworks/TreeSitterKit.xcframework (tree-sitter and the editor's
# grammars, one static library) and Frameworks/TreeSitterQueries (what the
# editor colours, indents and injects, per language) from pinned sources.
#
# The grammars and the queries come as a set: the queries are Helix's (MPL-2.0,
# copied unmodified; LICENSE alongside) at HELIX_REF, and each grammar is the
# revision that Helix release pins in its languages.toml — a query written for
# another revision of a grammar fails to compile on a renamed node. To bump:
# move HELIX_REF, then copy every grammar's rev from that tag's languages.toml.
set -euo pipefail

TREE_SITTER_REPO="https://github.com/tree-sitter/tree-sitter.git"
TREE_SITTER_REF="v0.25.10"
HELIX_REPO="https://github.com/helix-editor/helix.git"
HELIX_REF="25.07.1"
HELIX_SHA="a05c151bb6e8e9c65ec390b0ae2afe7a5efd619b"

# name | repository | revision | subdirectory (or -)
GRAMMARS=(
  "swift|https://github.com/alex-pinkus/tree-sitter-swift|57c1c6d6ffa1c44b330182d41717e6fe37430704|-"
  "go|https://github.com/tree-sitter/tree-sitter-go|64457ea6b73ef5422ed1687178d4545c3e91334a|-"
  "typescript|https://github.com/tree-sitter/tree-sitter-typescript|b1bf4825d9eaa0f3bdeb1e52f099533328acfbdf|typescript"
  "tsx|https://github.com/tree-sitter/tree-sitter-typescript|b1bf4825d9eaa0f3bdeb1e52f099533328acfbdf|tsx"
  "javascript|https://github.com/tree-sitter/tree-sitter-javascript|f772967f7b7bc7c28f845be2420a38472b16a8ee|-"
  "rust|https://github.com/tree-sitter/tree-sitter-rust|1f63b33efee17e833e0ea29266dd3d713e27e321|-"
  "python|https://github.com/tree-sitter/tree-sitter-python|4bfdd9033a2225cc95032ce77066b7aeca9e2efc|-"
  "json|https://github.com/tree-sitter/tree-sitter-json|73076754005a460947cafe8e03a8cf5fa4fa2938|-"
  "bash|https://github.com/tree-sitter/tree-sitter-bash|487734f87fd87118028a65a4599352fa99c9cde8|-"
  "c|https://github.com/tree-sitter/tree-sitter-c|7175a6dd5fc1cee660dce6fe23f6043d75af424a|-"
  "cpp|https://github.com/tree-sitter/tree-sitter-cpp|56455f4245baf4ea4e0881c5169de69d7edd5ae7|-"
  "markdown|https://github.com/tree-sitter-grammars/tree-sitter-markdown|62516e8c78380e3b51d5b55727995d2c511436d8|tree-sitter-markdown"
  "markdown_inline|https://github.com/tree-sitter-grammars/tree-sitter-markdown|62516e8c78380e3b51d5b55727995d2c511436d8|tree-sitter-markdown-inline"
  "yaml|https://github.com/ikatyang/tree-sitter-yaml|0e36bed171768908f331ff7dff9d956bae016efb|-"
  "toml|https://github.com/ikatyang/tree-sitter-toml|7cff70bbcbbc62001b465603ca1ea88edd668704|-"
  "zig|https://github.com/tree-sitter-grammars/tree-sitter-zig|eb7d58c2dc4fbeea4745019dee8df013034ae66b|-"
  "sql|https://github.com/DerekStride/tree-sitter-sql|b9d109588d5b5ed986c857464830c2f0bef53f18|-"
  "html|https://github.com/tree-sitter/tree-sitter-html|cbb91a0ff3621245e890d1c50cc811bffb77a26b|-"
  "css|https://github.com/tree-sitter/tree-sitter-css|769203d0f9abe1a9a691ac2b9fe4bb4397a73c51|-"
  "dockerfile|https://github.com/camdencheek/tree-sitter-dockerfile|087daa20438a6cc01fa5e6fe6906d77c869d19fe|-"
  "make|https://github.com/alemuller/tree-sitter-make|a4b9187417d6be349ee5fd4b6e77b4172c6827dd|-"
  "lua|https://github.com/tree-sitter-grammars/tree-sitter-lua|88e446476a1e97a8724dff7a23e2d709855077f2|-"
  "ruby|https://github.com/tree-sitter/tree-sitter-ruby|206c7077164372c596ffa8eaadb9435c28941364|-"
  "java|https://github.com/tree-sitter/tree-sitter-java|09d650def6cdf7f479f4b78f595e9ef5b58ce31e|-"
  "kotlin|https://github.com/fwcd/tree-sitter-kotlin|c4ddea359a7ff4d92360b2efcd6cfce5dc25afe6|-"
  "diff|https://github.com/the-mikedavis/tree-sitter-diff|fd74c78fa88a20085dbc7bbeaba066f4d1692b63|-"
)
# Helix query directories the languages above inherit from ("; inherits: ecma").
QUERY_EXTRAS=(ecma _javascript _typescript _jsx)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/tree-sitter"
BUILD="$VENDOR/build"
OUT="$ROOT/Frameworks/TreeSitterKit.xcframework"
QUERIES="$ROOT/Frameworks/TreeSitterQueries"

# A checkout of `repo` at exactly `rev` in `dir`: fetched by commit, so a moved
# tag or branch can't change what is built.
checkout() {
  local repo="$1" rev="$2" dir="$3"
  if [[ -d "$dir/.git" && "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" == "$rev" ]]; then return; fi
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init --quiet
  git -C "$dir" fetch --quiet --depth 1 "$repo" "$rev"
  git -C "$dir" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
  local actual
  actual="$(git -C "$dir" rev-parse HEAD)"
  if [[ "$actual" != "$rev" ]]; then
    echo "error: $repo at $rev resolved to $actual" >&2
    exit 1
  fi
}

echo "==> fetching tree-sitter $TREE_SITTER_REF, Helix $HELIX_REF queries, ${#GRAMMARS[@]} grammars"
if [[ ! -d "$VENDOR/tree-sitter/.git" ]] || [[ "$(git -C "$VENDOR/tree-sitter" describe --tags 2>/dev/null)" != "$TREE_SITTER_REF" ]]; then
  rm -rf "$VENDOR/tree-sitter"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TREE_SITTER_REF" "$TREE_SITTER_REPO" "$VENDOR/tree-sitter"
fi
if [[ ! -d "$VENDOR/helix/.git" || "$(git -C "$VENDOR/helix" rev-parse HEAD)" != "$HELIX_SHA" ]]; then
  rm -rf "$VENDOR/helix"
  git -c advice.detachedHead=false clone --quiet --depth 1 --filter=blob:none --sparse --branch "$HELIX_REF" "$HELIX_REPO" "$VENDOR/helix"
  git -C "$VENDOR/helix" sparse-checkout set runtime/queries
  if [[ "$(git -C "$VENDOR/helix" rev-parse HEAD)" != "$HELIX_SHA" ]]; then
    echo "error: Helix $HELIX_REF moved" >&2
    exit 1
  fi
fi
# Grammars sharing a repository (typescript/tsx, markdown) share a checkout,
# fetched once: two fetches into one directory race for its lock.
fetches=()
fetched=" "
for entry in "${GRAMMARS[@]}"; do
  IFS='|' read -r name repo rev _ <<<"$entry"
  dir="$VENDOR/repos/$(basename "$repo")-${rev:0:12}"
  [[ "$fetched" == *" $dir "* ]] && continue
  fetched+="$dir "
  checkout "$repo" "$rev" "$dir" &
  fetches+=($!)
done
for fetch in "${fetches[@]}"; do wait "$fetch"; done

echo "==> compiling (native arch, -O2)"
rm -rf "$BUILD"
mkdir -p "$BUILD/obj" "$BUILD/include/tree_sitter"
CFLAGS=(-O2 -fPIC -mmacosx-version-min=13.0 -w)
jobs=()
compile() { # source, object, include dirs…
  local source="$1" object="$2"
  shift 2
  local flags=("${CFLAGS[@]}")
  [[ "$source" == *.cc || "$source" == *.cpp ]] && flags=(-std=c++17 "${flags[@]}") || flags=(-std=c11 "${flags[@]}")
  clang -c "$source" -o "$object" "${flags[@]}" "$@" &
  jobs+=($!)
}
TS="$VENDOR/tree-sitter/lib"
# The library's own symbols stay visible: the app calls them.
clang -c "$TS/src/lib.c" -o "$BUILD/obj/tree-sitter.o" -std=c11 -O2 -fPIC -mmacosx-version-min=13.0 -w -I"$TS/include" -I"$TS/src" &
jobs+=($!)
HEADER="$BUILD/include/TreeSitterKit.h"
{
  echo "// Generated by Scripts/build-treesitter.sh."
  echo "#include \"tree_sitter/api.h\""
} >"$HEADER"
for entry in "${GRAMMARS[@]}"; do
  IFS='|' read -r name repo rev sub <<<"$entry"
  dir="$VENDOR/repos/$(basename "$repo")-${rev:0:12}"
  [[ "$sub" != "-" ]] && dir="$dir/$sub"
  if [[ ! -f "$dir/src/parser.c" ]]; then
    echo "error: $name has no generated src/parser.c at $rev" >&2
    exit 1
  fi
  compile "$dir/src/parser.c" "$BUILD/obj/$name-parser.o" -I"$dir/src"
  for scanner in "$dir/src/scanner.c" "$dir/src/scanner.cc"; do
    [[ -f "$scanner" ]] && compile "$scanner" "$BUILD/obj/$name-scanner.o" -I"$dir/src"
  done
  echo "const TSLanguage *tree_sitter_$name(void);" >>"$HEADER"
done
for job in "${jobs[@]}"; do wait "$job"; done

libtool -static -o "$BUILD/libtreesitterkit.a" "$BUILD"/obj/*.o 2>/dev/null
cp "$TS/include/tree_sitter/api.h" "$BUILD/include/tree_sitter/api.h"
cat >"$BUILD/include/module.modulemap" <<'MAP'
module TreeSitterKit {
    umbrella header "TreeSitterKit.h"
    export *
}
MAP

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework -library "$BUILD/libtreesitterkit.a" -headers "$BUILD/include" -output "$OUT" >/dev/null

echo "==> queries"
rm -rf "$QUERIES"
mkdir -p "$QUERIES"
for entry in "${GRAMMARS[@]}"; do
  IFS='|' read -r name _ <<<"$entry"
  helix_name="$name"
  [[ "$name" == "markdown_inline" ]] && helix_name="markdown.inline"
  [[ -d "$VENDOR/helix/runtime/queries/$helix_name" ]] && cp -R "$VENDOR/helix/runtime/queries/$helix_name" "$QUERIES/$name"
done
for extra in "${QUERY_EXTRAS[@]}"; do
  cp -R "$VENDOR/helix/runtime/queries/$extra" "$QUERIES/$extra"
done
curl -sSfL -o "$QUERIES/LICENSE" "https://raw.githubusercontent.com/helix-editor/helix/$HELIX_REF/LICENSE" ||
  cp "$VENDOR/helix/LICENSE" "$QUERIES/LICENSE" 2>/dev/null || true
echo "==> done: $OUT, $QUERIES"
