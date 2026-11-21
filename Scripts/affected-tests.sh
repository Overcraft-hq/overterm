#!/usr/bin/env bash
# Which unit tests a change reaches — for pull requests and `make test-changed`;
# main runs every test (docs/testing.md, Choosing tests).
#
# Reads the changed paths (one a line, relative to the repository) on stdin
# and prints one line:
#   all     — run the whole suite
#   none    — nothing a unit test can see changed (docs, the E2E scenarios' text…)
#   <regex> — a `swift test --filter` for the test classes reached
#
# A test class is reached when its file is changed, or when it names a type
# a changed source file declares or extends, or a type, function or constant
# a changed test file declares for the others (a helper, a fake). That is a
# test's direct reach, not every caller's: something that changes behaviour
# three types away can pass here and fail on main — which is why main runs
# everything.
#
# Anything the whole app depends on (the package, its resources, the
# scripts, a fixture, a deleted source file, a source file with a top-level
# function or global) is `all`; a rename is a deletion and an addition, so
# callers pass `git diff --no-renames`. GNU and BSD tools alike, and bash
# 3.2: CI runs it on Linux, people on macOS's /bin/bash.
set -euo pipefail

cd "$(dirname "$0")/.."

tests_dir=Tests/OvertermTests
changed=()
while IFS= read -r path; do
  [[ -n "$path" ]] && changed+=("$path")
done

if ((${#changed[@]} == 0)); then
  echo none
  exit 0
fi

# Top-level declarations only: a nested `Command` or `Action` would reach
# every test that says the word, and its parent's name reaches its own.
# (Kept out of the `<(…)` below: bash 3.2, macOS's, can't parse a quote or a
# backtick in a comment inside a process substitution.)
attributes='^(@[A-Za-z]+(\([^)]*\))?[[:space:]]+)*'
type_pattern="${attributes}((public|private|fileprivate|internal|package|final|nonisolated|indirect)[[:space:]]+)*(class|struct|enum|actor|protocol|extension|typealias)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*"
# A global, a function or a constant at the top level that another file can
# see: whatever calls it is found by no type name.
global_pattern="${attributes}((public|internal|package|nonisolated(\([a-z]+\))?)[[:space:]]+)*(func|let|var)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*"

names=()
files=()
for path in "${changed[@]}"; do
  case "$path" in
    Package.swift | Package.resolved | Makefile | mise.toml | Resources/* | Scripts/* | Frameworks/* | "$tests_dir"/Fixtures/*)
      echo all
      exit 0
      ;;
    "$tests_dir"/*.swift)
      if [[ -f "$path" ]]; then
        files+=("$path")
        # What it declares for the other test files (a helper, a fake, an
        # extension): those that name it are reached too. Its private ones
        # are its own.
        while IFS= read -r name; do names+=("$name"); done < <(
          grep -oE "$type_pattern|$global_pattern" "$path" |
            grep -vE '(^|[[:space:]])(private|fileprivate)[[:space:]]' |
            awk '{print $NF}'
        )
      fi
      ;;
    Sources/*.swift)
      # A file gone: what named its types can't be found from it.
      if [[ ! -f "$path" ]]; then
        echo all
        exit 0
      fi
      if grep -qE "$global_pattern" "$path"; then
        echo all
        exit 0
      fi
      base="$(basename "$path" .swift)"
      names+=("${base%%+*}")
      while IFS= read -r name; do names+=("$name"); done < <(
        grep -oE "$type_pattern" "$path" | awk '{print $NF}'
      )
      ;;
  esac
done

if ((${#names[@]} > 0)); then
  list="$(mktemp)"
  trap 'rm -f "$list"' EXIT
  printf '%s\n' "${names[@]}" | sort -u >"$list"
  while IFS= read -r file; do files+=("$file"); done < <(grep -lwF -f "$list" "$tests_dir"/*.swift || true)
fi

if ((${#files[@]} == 0)); then
  echo none
  exit 0
fi

classes="$(
  printf '%s\n' "${files[@]}" | sort -u | while IFS= read -r file; do
    # A helper with no test class of its own is no failure.
    { grep -oE '^(final[[:space:]]+)?class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase' "$file" || true; } |
      sed -E 's/^(final[[:space:]]+)?class[[:space:]]+([A-Za-z0-9_]+).*/\2/'
  done | sort -u
)"
if [[ -z "$classes" ]]; then
  echo none
  exit 0
fi

# Most of the suite reached: the whole of it costs no more, and says more.
total="$(cat "$tests_dir"/*.swift | grep -cE '^(final[[:space:]]+)?class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase' || true)"
count="$(wc -l <<<"$classes" | tr -d ' ')"
if ((count * 10 >= total * 7)); then
  echo all
  exit 0
fi

echo "OvertermTests\\.($(paste -sd '|' - <<<"$classes"))/"
