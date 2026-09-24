#!/usr/bin/env bash
#
# A daemon of its own, built from this checkout, for driving the daemon and
# the TUI over SSH by hand. Its release, config, store, keys and logs all live
# under one directory; ~/.config/tars and ~/.ssh are never read or written.
#
#   dev/daemon.sh              build and start the daemon, and open a shell on it
#   dev/daemon.sh COMMAND      run a `tars` command against it, from any terminal
#
# In that shell, `tars` is the release's bin/tars pointed at this daemon, and
# `tars attach` connects with a key of its own:
#
#   tars attach            the TUI over SSH; Ctrl-D, /quit or Ctrl-C leaves it
#   tars status            what it is running, attached or not
#   tars logs              follow its log
#   tars stop; tars start  restart the node, keeping its store
#
# Leaving the shell, or closing its terminal, stops the daemon and removes the
# directory, and a run that ended without doing so is cleaned up by the next.
# The node is tarsd_dev@localhost and SSH listens on the first free port from
# 2222, so it runs beside another daemon. Provider keys such as ZAI_API_KEY
# come from the environment it starts in.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
script="$root/dev/daemon.sh"
dir="${XDG_RUNTIME_DIR:-"${TMPDIR:-/tmp}"}/tars-dev"
node=tarsd_dev@localhost

tars() {
  TARS_CONFIG_DIR="$dir/config" TARS_DATA_HOME="$dir/data" TARS_STATE_DIR="$dir/state" \
    RELEASE_NODE="$node" "$dir/rel/bin/tars" "$@"
}

attach() {
  exec ssh -t -p "$(cat "$dir/port")" -i "$dir/id_ed25519" -o IdentitiesOnly=yes \
    -o UserKnownHostsFile="$dir/known_hosts" -o StrictHostKeyChecking=accept-new \
    -o LogLevel=ERROR "$(id -un)@localhost"
}

listening() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Whether the run that made $dir is still going.
owned() {
  local pid
  pid=$(cat "$dir/owner" 2>/dev/null) || return 1
  ps -o args= -p "$pid" 2>/dev/null | grep -q "daemon.sh"
}

cleanup() (
  set +e
  trap '' HUP INT TERM
  tars stop >/dev/null 2>&1 || pkill -f -- "$dir/rel/erts-" 2>/dev/null
  rm -rf "$dir"
)

if [ $# -gt 0 ]; then
  owned || { echo "No dev daemon is running; dev/daemon.sh starts one." >&2; exit 1; }
  [ "$1" = attach ] && attach
  tars "$@"
  exit
fi

if [ -e "$dir" ] && [ ! -O "$dir" ]; then
  echo "$dir belongs to another user." >&2
  exit 1
fi

if owned; then
  echo "A dev daemon is already running, from pid $(cat "$dir/owner"); dev/daemon.sh attach reaches it." >&2
  exit 1
fi

[ -e "$dir" ] && cleanup

mkdir -m 700 "$dir"
echo $$ >"$dir/owner"
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

(cd "$root" && MIX_ENV=prod mix release --path "$dir/rel" --overwrite --quiet >/dev/null)

mkdir -p "$dir/config/ssh" "$dir/bin"
ssh-keygen -q -t ed25519 -N "" -C tars-dev -f "$dir/id_ed25519"
cp "$dir/id_ed25519.pub" "$dir/config/ssh/authorized_keys"

port=2222
while listening "$port"; do port=$((port + 1)); done
echo "$port" >"$dir/port"
printf 'ssh:\n  port: %s\n' "$port" >"$dir/config/config.yaml"

tars start

for _ in $(seq 50); do
  listening "$port" && break
  sleep 0.1
done

if ! listening "$port"; then
  echo "The daemon started, but SSH is not listening on port $port:" >&2
  grep "SSH is not served" "$dir/state/log/tars.log" >&2 || true
  exit 1
fi

cat >"$dir/bin/tars" <<EOF
#!/bin/sh
[ \$# -gt 0 ] || set -- help
exec "$script" "\$@"
EOF
chmod +x "$dir/bin/tars"

cat <<EOF

$node is up, serving SSH on localhost:$port, from $dir.

  tars attach    the TUI over SSH; Ctrl-D, /quit or Ctrl-C leaves it
  tars status    what it is running
  tars logs      follow its log

dev/daemon.sh attach reaches it from another terminal. Leaving this shell
stops the daemon and removes $dir.

EOF

# Ctrl-C belongs to the shell and what it runs, not to this script.
trap : INT
PATH="$dir/bin:$PATH" "${SHELL:-/bin/sh}" || true
