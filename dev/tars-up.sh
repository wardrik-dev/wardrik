#!/usr/bin/env bash
#
# Starts a daemon for a long run, such as a soak test: a release built from
# this checkout into ~/tars, started in the background with the keys and
# tokens ~/.config/tars/env holds. Unlike dev/daemon.sh it reads the real
# ~/.config/tars and keeps its store under ~/.local/share/tars, and it outlives
# the terminal that started it.
#
#   dev/tars-up.sh           start it, building the release first if there is none
#   dev/tars-up.sh --build   build the release again from this checkout, then start it
#
# The env file is sh, one NAME=value a line:
#
#   ANTHROPIC_API_KEY=sk-ant-...
#   SLACK_BOT_TOKEN=xoxb-...
#
# It should be readable by its owner only. TARS_RELEASE and TARS_ENV_FILE move
# the release and the env file. Stop the daemon with ~/tars/bin/tars stop.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
release="${TARS_RELEASE:-"$HOME/tars"}"
env_file="${TARS_ENV_FILE:-"${XDG_CONFIG_HOME:-"$HOME/.config"}/tars/env"}"

running() {
  "$release/bin/tarsd" pid >/dev/null 2>&1
}

if [ "${1:-}" = --build ] || [ ! -x "$release/bin/tars" ]; then
  if [ -x "$release/bin/tars" ] && running; then
    echo "The daemon in $release is running; stop it with $release/bin/tars stop before building over it." >&2
    exit 1
  fi

  (cd "$root" && MIX_ENV=prod mix release --path "$release" --overwrite --quiet >/dev/null)
fi

if [ -f "$env_file" ]; then
  if [ -n "$(find "$env_file" \( -perm -040 -o -perm -004 \) 2>/dev/null)" ]; then
    echo "$env_file can be read by others; chmod 600 it." >&2
  fi

  set -a
  # shellcheck source=/dev/null
  . "$env_file"
  set +a
else
  echo "There is no $env_file, so the daemon gets this shell's environment." >&2
fi

"$release/bin/tars" start
"$release/bin/tars" status
