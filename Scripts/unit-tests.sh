#!/usr/bin/env bash
# Runs the built unit tests (`swift build --build-tests` first) several
# processes at once — `make test` and CI (docs/testing.md, Choosing tests).
#
#   Scripts/unit-tests.sh [workers] [regex]
#
# workers: processes at once (default: one a core). regex: only the tests
# whose `swift test --list-tests` name matches (Scripts/affected-tests.sh's
# filter). UNIT_TEST_LOGS: where each process's log is left (default: a
# temporary folder); the logs are printed whole at the end, failures last.
#
# Why not `swift test --parallel`: on macOS it starts one xctest process a
# test — 4,350 of them, each loading the whole debug build — and with four
# at once that took 378 s here against 309 s in one process. These are
# chunks of whole classes, eight chunks a worker, each its own xctest
# process, the classes dealt round the chunks (so Kubernetes' slow ones are
# spread out) and the chunks handed to whichever worker is free.
#
# bash 3.2 (macOS's /bin/bash): no mapfile, no associative arrays.
set -euo pipefail

cd "$(dirname "$0")/.."

workers=${1:-$(sysctl -n hw.ncpu)}
# Checked before arithmetic sees it: bash evaluates `a[$(…)]` there.
[[ $workers =~ ^[1-9][0-9]*$ ]] || { echo "workers must be a positive integer, not '$workers'." >&2; exit 2; }
regex=${2:-}
bundle="$(swift build --show-bin-path)/OvertermTests.xctest"
[[ -d "$bundle" ]] || { echo "No $bundle: run swift build --build-tests first." >&2; exit 1; }

logs=${UNIT_TEST_LOGS:-$(mktemp -d "${TMPDIR:-/tmp}/overterm-unit-tests.XXXXXX")}
mkdir -p "$logs"
rm -f "$logs"/chunk-*

listed=$(swift test --skip-build --list-tests 2>/dev/null | grep '^OvertermTests\.' || true)
if [[ -n "$regex" ]]; then listed=$(grep -E -- "$regex" <<<"$listed" || true); fi
classes=$(cut -d/ -f1 <<<"$listed" | sort -u)
count=$(grep -c . <<<"$classes" || true)
if [[ "$count" -eq 0 ]]; then
  echo "No unit test matches ${regex:-anything}." >&2
  exit 1
fi

chunks=$((workers * 8))
[[ $chunks -gt $count ]] && chunks=$count
i=0
# Whole classes a chunk; with a filter, only the tests of each class it
# picked (one method named runs that method, not its siblings).
while IFS= read -r class; do
  chunk="$logs/chunk-$(printf %03d $((i % chunks))).classes"
  if [[ -n "$regex" ]]; then
    awk -F/ -v class="$class" '$1 == class' <<<"$listed" >>"$chunk"
  else
    echo "$class" >>"$chunk"
  fi
  i=$((i + 1))
done <<<"$classes"
echo "$count test classes in $chunks processes, $workers at once (logs: $logs)"

# A chunk still running after UNIT_TEST_TIMEOUT seconds (default 600; the
# slowest takes well under a minute) is a test that hangs: killed, its log
# ending at the test that was running.
run_chunk() {
  local list=$1 log=${1%.classes}.log ticks=0 status=0
  xcrun xctest -XCTest "$(paste -sd, "$list")" "$2" >"$log" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null && [[ $ticks -lt $((${UNIT_TEST_TIMEOUT:-600} * 5)) ]]; do
    sleep 0.2
    ticks=$((ticks + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    echo "timed out after $((ticks / 5)) s" >>"$log"
  fi
  wait "$pid" || status=$?
  if [[ $status -ne 0 ]]; then
    echo "exit $status" >>"$log"
    touch "${1%.classes}.failed"
    return 1
  fi
}
export -f run_chunk

start=$SECONDS
status=0
ls "$logs"/chunk-*.classes | xargs -P "$workers" -I{} bash -c 'run_chunk "$1" "$2"' _ {} "$bundle" || status=$?
elapsed=$((SECONDS - start))

for log in "$logs"/chunk-*.log; do
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::group::$(basename "$log")"; fi
  cat "$log"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::endgroup::"; fi
done

executed=$(cat "$logs"/chunk-*.log | grep -E "^Test Case '.*' (passed|failed|skipped)" | grep -c . || true)
failed=$(ls "$logs"/chunk-*.failed 2>/dev/null | grep -c . || true)
echo
echo "$executed tests in $elapsed s, $failed of $chunks processes failed."
if [[ $status -ne 0 || $failed -ne 0 ]]; then
  for marker in "$logs"/chunk-*.failed; do
    [[ -e "$marker" ]] || continue
    log=${marker%.failed}.log
    echo "--- $(basename "$log"): $(paste -sd' ' "${marker%.failed}.classes")"
    grep -E "error: |' failed \(|^exit [0-9]+|^timed out|Fatal error|signal " "$log" || tail -20 "$log"
  done
  exit 1
fi
