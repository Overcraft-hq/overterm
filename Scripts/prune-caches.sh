#!/usr/bin/env bash
# Deletes this ref's build caches whose key starts with PREFIX, all but KEEP
# (the one just saved): each ref keeps its newest, so a key a commit stays
# within the repository's 10 GB. Another ref's (main's, another pull
# request's) are never touched. CI's; needs GH_TOKEN with actions: write.
#
# Usage: Scripts/prune-caches.sh PREFIX KEEP
set -euo pipefail

prefix="$1"
keep="$2"
ref="${GITHUB_REF:?GITHUB_REF names the ref of the run}"

ids="$(gh cache list --ref "$ref" --key "$prefix" --limit 100 --json id,key \
  --jq ".[] | select(.key != \"$keep\") | .id")"
for id in $ids; do
  gh cache delete "$id"
  echo "deleted cache $id ($ref)"
done
[[ -n "$ids" ]] || echo "nothing older under $prefix on $ref"
