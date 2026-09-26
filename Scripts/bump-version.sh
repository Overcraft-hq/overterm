#!/usr/bin/env bash
# Bump the app's version for the commit being made (CLAUDE.md, Commits):
#
#   Scripts/bump-version.sh major|minor|patch "what changed"
#
# Sets VERSION one step past the committed one and adds the line to
# CHANGELOG.md, under a heading for the new version and today's date. Run
# again before committing, it adds to that entry: the bump counts from the
# VERSION in HEAD, so it never bumps twice. Commit both files with the change.
# Runs on macOS's bash 3.2.
set -euo pipefail

usage() {
  echo 'usage: Scripts/bump-version.sh major|minor|patch "what changed"' >&2
  echo '  major: incompatible (a saved-state format older versions cannot read, a removed feature or shortcut)' >&2
  echo '  minor: a new user-visible feature or capability' >&2
  echo '  patch: a fix, performance work, polish, or an internal step of a larger feature' >&2
  exit 2
}

[[ $# -eq 2 ]] || usage
part="$1"
summary="$2"
case "$part" in
  major | minor | patch) ;;
  *) usage ;;
esac
# One line, trimmed: it becomes one bullet.
[[ "$summary" != *$'\n'* ]] || usage
summary="${summary#"${summary%%[![:space:]]*}"}"
summary="${summary%"${summary##*[![:space:]]}"}"
[[ -n "$summary" ]] || usage

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/VERSION"
CHANGELOG="$ROOT/CHANGELOG.md"
for file in "$VERSION_FILE" "$CHANGELOG"; do
  [[ -f "$file" ]] || { echo "error: $file missing" >&2; exit 1; }
done

# The committed version, so that a second run bumps from the same one; the
# file's where there is none (no git, or VERSION never committed yet).
base="$(git -C "$ROOT" show HEAD:./VERSION 2>/dev/null || cat "$VERSION_FILE")"
base="$(printf '%s' "$base" | tr -d '[:space:]')"
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "$base" =~ $semver ]]; then
  echo "error: VERSION is '$base', not MAJOR.MINOR.PATCH" >&2
  exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
case "$part" in
  major) new="$((major + 1)).0.0" ;;
  minor) new="$major.$((minor + 1)).0" ;;
  patch) new="$major.$minor.$((patch + 1))" ;;
esac
today="$(date +%Y-%m-%d)"
heading="## $new — $today"
bullet="- $summary"

lines=()
while IFS= read -r line || [[ -n "$line" ]]; do
  lines+=("$line")
done <"$CHANGELOG"
count=${#lines[@]}

# The top entry, and where the next one starts.
top=-1
next=$count
for ((i = 0; i < count; i++)); do
  if [[ "${lines[i]}" == "## "* ]]; then
    if ((top < 0)); then
      top=$i
    else
      next=$i
      break
    fi
  fi
done

updated="$(mktemp)"
trap 'rm -f "$updated"' EXIT
if ((top >= 0)) && [[ "${lines[top]}" == "## $new — "* ]]; then
  # This commit's entry, from an earlier run: add the line after its last one.
  last=$top
  for ((i = top + 1; i < next; i++)); do
    if [[ "${lines[i]}" == "$bullet" ]]; then
      echo "CHANGELOG.md already has \"$bullet\" under $new; nothing to do"
      exit 0
    fi
    if [[ -n "${lines[i]//[[:space:]]/}" ]]; then last=$i; fi
  done
  for ((i = 0; i < count; i++)); do
    if ((i == top)); then printf '%s\n' "$heading"; else printf '%s\n' "${lines[i]}"; fi
    if ((i == last)); then printf '%s\n' "$bullet"; fi
  done >"$updated"
  what="added to the $new entry"
elif ((top >= 0)); then
  for ((i = 0; i < count; i++)); do
    if ((i == top)); then printf '%s\n\n%s\n\n' "$heading" "$bullet"; fi
    printf '%s\n' "${lines[i]}"
  done >"$updated"
  what="new entry $new"
else
  # No entry yet: the first goes after the preamble.
  {
    for ((i = 0; i < count; i++)); do printf '%s\n' "${lines[i]}"; done
    if ((count > 0)) && [[ -n "${lines[count - 1]}" ]]; then printf '\n'; fi
    printf '%s\n\n%s\n' "$heading" "$bullet"
  } >"$updated"
  what="first entry $new"
fi

# In place, keeping the files' modes.
cat "$updated" >"$CHANGELOG"
printf '%s\n' "$new" >"$VERSION_FILE"
echo "VERSION $base -> $new; CHANGELOG.md: $what ($today)"
echo "Commit VERSION and CHANGELOG.md with the change."
