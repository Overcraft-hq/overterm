#!/usr/bin/env bash
# Every tracked file's modification time set to its last commit's time.
#
# A checkout gives each file the time it was written, so Swift Build takes
# every source for changed and rebuilds the app's modules whole, a restored
# build cache or not. With the commit's time an unchanged file reads as it
# did when the cache was made, and only what a commit changed is rebuilt.
# One `git log` over the history, newest first: a file's first appearance
# is its last change. Files no commit names (none, in a clean checkout)
# are left as they are.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
git log --format='%ct' --name-only --no-renames -- "${@:-.}" | python3 -c '
import os, sys
seen = set()
when = None
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    if line.isdigit():
        when = int(line)
        continue
    if line in seen or when is None:
        continue
    seen.add(line)
    if os.path.isfile(line) and not os.path.islink(line):
        os.utime(line, (when, when))
print(f"{len(seen)} files dated by their last commit", file=sys.stderr)
'
