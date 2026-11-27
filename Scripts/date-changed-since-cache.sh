#!/usr/bin/env bash
# The files changed since a restored build cache's commit, dated now.
#
# restore-mtimes.sh dates every file by its last commit, so what a commit
# didn't change reads as it did when the cache was saved. But a branch's
# commit can be older than the cache it is built on: #67's was written at
# 16:22 and merged after main's cache of 18:18 was saved, so its files
# carried a time before that cache and Swift Build took them for built —
# main's tests ran the old SettingsSchema and failed where the PR passed.
# Whatever changed between the cache's commit and HEAD is dated now, which
# is after any cache.
#
# $1: the restored entry's key (actions/cache's `cache-matched-key`), whose
# last part is the commit it was saved at. No key: nothing was restored and
# nothing needs dating. A commit this checkout doesn't have: every file.
set -euo pipefail

key="${1:-}"
if [[ -z "$key" ]]; then
  echo "No build cache restored: nothing to date."
  exit 0
fi
cd "$(git rev-parse --show-toplevel)"
base="${key##*-}"
if [[ "$base" =~ ^[0-9a-f]{40}$ ]] && git cat-file -e "$base^{commit}" 2>/dev/null; then
  changed="$(git diff --name-only --no-renames "$base" HEAD)"
  what="changed since $base"
else
  changed="$(git ls-files)"
  what="all (the cache's commit, ${base:-none}, isn't here)"
fi
count=0
while IFS= read -r file; do
  if [[ -n "$file" && -f "$file" && ! -L "$file" ]]; then
    touch "$file"
    count=$((count + 1))
  fi
done <<<"$changed"
echo "$count files dated now: $what"
