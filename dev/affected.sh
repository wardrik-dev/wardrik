#!/usr/bin/env bash
#
# The Mix projects a change touches, as the JSON array CI's matrix takes: each
# project whose files changed, and each that depends on one that did, as its
# mix.exs names the packages beside it. A change to what every project builds
# with, the CI workflow, tools/precommit, .credo.exs or mise.toml, touches
# them all.
#
#   dev/affected.sh origin/main     what changed since this branch left main
#   dev/affected.sh --all           every project
set -euo pipefail

cd "$(dirname "$0")/.."

projects=(packages/* release)

json() {
  local first=1
  printf '['
  for project in "$@"; do
    [ "$first" = 1 ] || printf ','
    printf '"%s"' "$project"
    first=0
  done
  printf ']\n'
}

if [ "${1:-}" = --all ]; then
  json "${projects[@]}"
  exit 0
fi

base=${1:?usage: dev/affected.sh BASE | --all}
changed=$(git diff --name-only "$(git merge-base "$base" HEAD)" HEAD)

if grep -qE '^(\.github/|tools/|\.credo\.exs$|mise\.toml$)' <<<"$changed"; then
  json "${projects[@]}"
  exit 0
fi

# The packages a project's mix.exs depends on, by their directories.
siblings() {
  grep -oE 'sibling\(:wardrik[a-z0-9_]*|path: "\.\./packages/wardrik[a-z0-9_]*' "$1/mix.exs" |
    sed -E 's#.*(wardrik[a-z0-9_]*)$#packages/\1#' | sort -u
}

declare -A affected=()
for project in "${projects[@]}"; do
  if grep -q "^$project/" <<<"$changed"; then affected[$project]=1; fi
done

# A project is affected where anything it depends on is, until nothing more is.
grew=1
while [ "$grew" = 1 ]; do
  grew=0
  for project in "${projects[@]}"; do
    [ -n "${affected[$project]:-}" ] && continue
    for sibling in $(siblings "$project"); do
      if [ -n "${affected[$sibling]:-}" ]; then
        affected[$project]=1
        grew=1
        break
      fi
    done
  done
done

result=()
for project in "${projects[@]}"; do
  if [ -n "${affected[$project]:-}" ]; then result+=("$project"); fi
done
json "${result[@]}"
