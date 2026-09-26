#!/usr/bin/env bash
#
# Deletes the box deploy/hetzner/bootstrap.sh made, with its firewall and the
# SSH key bootstrap.sh uploaded for it, and forgets the box's host keys. A key
# Hetzner already had is left where it was.
#
#   deploy/hetzner/teardown.sh      # asks first
#   deploy/hetzner/teardown.sh -y   # does not
#
# WARDRIK_BOX names the box, wardrik-demo by default. The GitHub token it was
# authorized with dies with the box's vault key, and GitHub goes on accepting
# it until the OAuth app is revoked. Issues it opened stay open.
set -euo pipefail

box=${WARDRIK_BOX:-wardrik-demo}
local_wardrik="$HOME/wardrik/bin/wardrik"

die() { printf 'teardown: %s\n' "$*" >&2; exit 1; }

command -v hcloud >/dev/null || die "needs hcloud"
[ -n "${HCLOUD_TOKEN:-}" ] || [ -n "$(hcloud context active 2>/dev/null)" ] ||
  die "hcloud has no context; hcloud context use NAME"

if hcloud server describe "$box" >/dev/null 2>&1; then
  address=$(hcloud server ip "$box")

  if [ "${1:-}" != -y ]; then
    read -r -p "Delete the server $box, at $address, and everything on it? [y/N] " answer
    case "$answer" in
      y | Y | yes) ;;
      *) echo "Nothing was deleted."; exit 1 ;;
    esac
  fi

  hcloud server delete "$box" >/dev/null
  ssh-keygen -R "$address" >/dev/null 2>&1 || true
  ssh-keygen -R "[$address]:2222" >/dev/null 2>&1 || true
  echo "Deleted the server $box."
else
  echo "There is no server $box."
fi

# A firewall is released a moment after its server is gone.
if hcloud firewall describe "$box" >/dev/null 2>&1; then
  for _ in $(seq 10); do
    hcloud firewall delete "$box" >/dev/null 2>&1 && break
    sleep 3
  done

  if hcloud firewall describe "$box" >/dev/null 2>&1; then
    die "the firewall $box is still there; hcloud firewall delete $box"
  fi

  echo "Deleted the firewall $box."
fi

if hcloud ssh-key describe "$box" >/dev/null 2>&1; then
  hcloud ssh-key delete "$box" >/dev/null
  echo "Deleted the SSH key $box."
fi

if [ -x "$local_wardrik" ]; then
  echo "Your own daemon can have the Slack app back: $local_wardrik start"
fi
