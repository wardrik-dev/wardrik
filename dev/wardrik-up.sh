#!/usr/bin/env bash
#
# Starts a daemon for a long run, such as a soak test: a release built from
# this checkout into ~/wardrik, started in the background with the keys and
# tokens ~/.config/wardrik/env holds, which bin/wardrik reads. Unlike
# dev/daemon.sh it reads the real ~/.config/wardrik and keeps its store under
# ~/.local/share/wardrik, and it outlives the terminal that started it.
#
#   dev/wardrik-up.sh           start it, building the release first if there is none
#   dev/wardrik-up.sh --build   build the release again from this checkout, then start it
#
# WARDRIK_RELEASE and WARDRIK_ENV_FILE move the release and the env file. Stop
# the daemon with ~/wardrik/bin/wardrik stop.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
release="${WARDRIK_RELEASE:-"$HOME/wardrik"}"

running() {
  "$release/bin/wardrikd" pid >/dev/null 2>&1
}

if [ "${1:-}" = --build ] || [ ! -x "$release/bin/wardrik" ]; then
  if [ -x "$release/bin/wardrik" ] && running; then
    echo "The daemon in $release is running; stop it with $release/bin/wardrik stop before building over it." >&2
    exit 1
  fi

  (
    cd "$root/release" &&
      MIX_ENV=prod mix deps.get --only prod >/dev/null &&
      MIX_ENV=prod mix release --path "$release" --overwrite --quiet >/dev/null
  )
fi

"$release/bin/wardrik" start
"$release/bin/wardrik" status
