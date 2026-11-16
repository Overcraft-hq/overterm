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
# a changed source file declares or extends. That is a test's direct reach,
# not every caller's: something that changes behaviour three types away can
# pass here and fail on main — which is why main runs everything.
#
# Anything the whole app depends on (the package, its resources, the
# scripts, a fixture, a deleted source file) is `all`. GNU and BSD tools
# alike: CI runs it on Linux, people on macOS.
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

names=()
files=()
for path in "${changed[@]}"; do
  case "$path" in
    Package.swift | Package.resolved | Makefile | mise.toml | Resources/* | Scripts/* | Frameworks/* | "$tests_dir"/Fixtures/*)
      echo all
      exit 0
      ;;
    "$tests_dir"/*.swift)
      [[ -f "$path" ]] && files+=("$path")
      ;;
    Sources/*.swift)
      # A file gone: what named its types can't be found from it.
      if [[ ! -f "$path" ]]; then
        echo all
        exit 0
      fi
      base="$(basename "$path" .swift)"
      names+=("${base%%+*}")
      while IFS= read -r name; do names+=("$name"); done < <(
        # Top-level only: a nested `Command` or `Action` would reach every
        # test that says the word, and its parent's name reaches its own.
        grep -oE '^(@[A-Za-z]+[[:space:]]+)*((public|private|fileprivate|internal|package|final|nonisolated|indirect)[[:space:]]+)*(class|struct|enum|actor|protocol|extension)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$path" |
          awk '{print $NF}'
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
    grep -oE '^(final[[:space:]]+)?class[[:space:]]+[A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase' "$file" |
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
