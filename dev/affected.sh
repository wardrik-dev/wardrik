#!/usr/bin/env bash
#
# What CI runs for a change, as lines for GITHUB_OUTPUT:
#
#   check=[{"project":"packages/wardrik_mcp","only":"lint,test,dialyzer"}, ...]
#   release=true
#   arm=false
#   hosts=false
#   sdk=false
#   docs=false
#
# A project is checked for what changed in it: lint and its tests for any of
# its files, and dialyzer as well unless only its tests did. A project whose
# dependencies' lib/, priv/ or mix.exs changed runs its tests and dialyzer
# again, since what it builds against changed and its own source did not. A
# README or LICENSE alone checks nothing. A change to what every project
# builds with, the CI workflow, tools/precommit, .credo.exs or mise.toml,
# checks everything.
#
# The release is built and booted where what it ships changed, and on arm64
# as well where how it is built did: the Dockerfile, the daemon's mix.exs,
# configuration, rel/ and lockfile, where a native dependency arrives, or what
# installs and runs it. The host apps are made where core or its Postgres or
# S3 store changed, the TypeScript SDK is checked where it or the protocol's
# schemas did, and the docs site is built where it did.
#
#   dev/affected.sh origin/main     what changed since this branch left main
#   dev/affected.sh --all           everything
set -euo pipefail

cd "$(dirname "$0")/.."

projects=(packages/*)

if [ "${1:-}" = --all ]; then
  all=1
  changed=""
else
  base=${1:?usage: dev/affected.sh BASE | --all}
  changed=$(git diff --name-only "$(git merge-base "$base" HEAD)" HEAD | grep -vE '(^|/)(README\.md|LICENSE)$' || true)
  all=0
  if grep -qE '^(\.github/|tools/|\.credo\.exs$|mise\.toml$)' <<<"$changed"; then all=1; fi
fi

# The packages a project's mix.exs depends on, by their directories.
siblings() {
  grep -oE 'sibling\(:wardrik[a-z0-9_]*' "$1/mix.exs" |
    sed -E 's#.*(wardrik[a-z0-9_]*)$#packages/\1#' | sort -u
}

# What changed in each project: anything, anything but its tests, and what
# the projects depending on it build against.
declare -A own=() source=() public=() through=()
for project in "${projects[@]}"; do
  mine=$(grep "^$project/" <<<"$changed" || true)
  [ -n "$mine" ] || continue
  own[$project]=1
  if grep -qv "^$project/test/" <<<"$mine"; then source[$project]=1; fi
  if grep -qE "^$project/(lib/|priv/|mix\.exs$)" <<<"$mine"; then public[$project]=1; fi
done

# A project builds against a change where anything it depends on changed
# what it is built against, until nothing more does.
grew=1
while [ "$grew" = 1 ]; do
  grew=0
  for project in "${projects[@]}"; do
    [ -n "${through[$project]:-}" ] && continue
    for sibling in $(siblings "$project"); do
      if [ -n "${public[$sibling]:-}${through[$sibling]:-}" ]; then
        through[$project]=1
        grew=1
        break
      fi
    done
  done
done

entries=()
for project in "${projects[@]}"; do
  if [ "$all" = 1 ]; then
    only="lint,test,dialyzer"
  else
    groups=()
    if [ -n "${own[$project]:-}" ]; then groups+=(lint); fi
    if [ -n "${own[$project]:-}${through[$project]:-}" ]; then groups+=(test); fi
    if [ -n "${source[$project]:-}${through[$project]:-}" ]; then groups+=(dialyzer); fi
    only=$(IFS=,; echo "${groups[*]:-}")
  fi
  if [ -n "$only" ]; then entries+=("{\"project\":\"$project\",\"only\":\"$only\"}"); fi
done
echo "check=[$(IFS=,; echo "${entries[*]:-}")]"

job() {
  if [ "$all" = 1 ] || grep -qE "$1" <<<"$changed"; then echo true; else echo false; fi
}

build='packages/wardrik_daemon/(mix\.(exs|lock)$|config/(config|prod|runtime)\.exs$|rel/)'

echo "release=$(job "^(packages/[^/]+/(lib/|priv/|mix\.exs$)|$build|Dockerfile$|\.dockerignore$|deploy/|dev/(distros|service|failover|services)\.sh$)")"
echo "arm=$(job "^(Dockerfile$|\.dockerignore$|$build|deploy/|dev/(distros|service|failover)\.sh$)")"
echo "hosts=$(job '^(packages/(wardrik|wardrik_core)/(lib/|priv/|mix\.exs$)|dev/hosts|dev/services\.sh$)')"
echo "sdk=$(job '^(sdks/typescript/|packages/wardrik_core/priv/)')"
echo "docs=$(job '^docs/')"
