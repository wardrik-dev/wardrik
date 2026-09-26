#!/usr/bin/env bash
#
# Makes a Hetzner box of three wardrik nodes from the cloud-init.yaml beside this
# script, gives it the release CI built from main and the keys the daemon
# reads, and starts the nodes. Run again, it goes on from what is there, and
# puts the latest release in place of the one the box has.
#
#   SLACK_CHANNEL=C0123456789 deploy/hetzner/bootstrap.sh
#
# SLACK_CHANNEL is the id of a channel the Slack bot is in, where parked calls
# are posted; the env file may hold it instead. hcloud needs a context (hcloud
# context create wardrik) or HCLOUD_TOKEN, and gh a login that can read the
# repository.
#
#   WARDRIK_BOX            the server's name, wardrik-demo
#   WARDRIK_BOX_TYPE       cx23; an x86 type, since the release is built for x86_64
#   WARDRIK_BOX_LOCATION   fsn1
#   WARDRIK_SSH_KEY        the key that lets you in as wardrik and into the TUI: the first of
#                       ~/.ssh/id_ed25519.pub, id_ecdsa.pub and id_rsa.pub there is
#   WARDRIK_ENV_FILE       ~/.config/wardrik/env, the keys the daemon reads
#
# The firewall lets anyone reach SSH, and only this machine's address reach the
# TUI. The box shares its Slack app with any daemon of yours, so it is not made
# while one runs here. deploy/hetzner/teardown.sh deletes it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
repo=jonlunsford/tars
box=${WARDRIK_BOX:-wardrik-demo}
type=${WARDRIK_BOX_TYPE:-cx23}
location=${WARDRIK_BOX_LOCATION:-fsn1}
public_key=${WARDRIK_SSH_KEY:-}
if [ -z "$public_key" ]; then
  for candidate in id_ed25519 id_ecdsa id_rsa; do
    [ -f "$HOME/.ssh/$candidate.pub" ] && public_key="$HOME/.ssh/$candidate.pub" && break
  done
fi
env_file=${WARDRIK_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/wardrik/env}
local_wardrik="$HOME/wardrik/bin/wardrik"

say() { printf '==> %s\n' "$*"; }
die() { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }

for command in hcloud gh ssh scp ssh-keygen curl; do
  command -v "$command" >/dev/null || die "needs $command"
done

[ -n "${HCLOUD_TOKEN:-}" ] || [ -n "$(hcloud context active 2>/dev/null)" ] ||
  die "hcloud has no context; hcloud context create wardrik, with an API token from the Hetzner console"
[ -n "$public_key" ] && [ -f "$public_key" ] ||
  die "there is no public key at ${public_key:-~/.ssh}; set WARDRIK_SSH_KEY"
[ -f "$env_file" ] || die "there is no env file at $env_file; set WARDRIK_ENV_FILE"

channel=${SLACK_CHANNEL:-$(sed -n 's/^SLACK_CHANNEL=//p' "$env_file" | tail -n 1)}
[ -n "$channel" ] || die "set SLACK_CHANNEL to the id of a channel the Slack bot is in"

if [ -x "$local_wardrik" ] && "$local_wardrik" status >/dev/null 2>&1; then
  die "a daemon runs here, on the Slack app the box would share; stop it with $local_wardrik stop"
fi

# -- the box ------------------------------------------------------------------

if ! hcloud firewall describe "$box" >/dev/null 2>&1; then
  address=$(curl -fsS https://ipv4.icanhazip.com | tr -d '[:space:]')
  say "Making the firewall $box: SSH from anywhere, the TUI from $address"
  hcloud firewall create --name "$box" >/dev/null
  hcloud firewall add-rule "$box" --direction in --protocol tcp --port 22 \
    --source-ips 0.0.0.0/0 --source-ips ::/0 >/dev/null
  hcloud firewall add-rule "$box" --direction in --protocol tcp --port 2222 \
    --source-ips "$address/32" >/dev/null
fi

# A key Hetzner already has is used under its own name; one it does not is
# uploaded under the box's, for teardown.sh to delete with it.
fingerprint=$(ssh-keygen -E md5 -lf "$public_key" | awk '{print $2}' | sed 's/^MD5://')
key=$(hcloud ssh-key list -o noheader -o columns=name,fingerprint |
  awk -v fingerprint="$fingerprint" '$2 == fingerprint {print $1; exit}')

if [ -z "$key" ]; then
  say "Uploading $public_key to Hetzner as $box"
  hcloud ssh-key create --name "$box" --public-key-from-file "$public_key" >/dev/null
  key=$box
fi

if ! hcloud server describe "$box" >/dev/null 2>&1; then
  say "Making the server $box, $type in $location"
  hcloud server create --name "$box" --type "$type" --image ubuntu-24.04 \
    --location "$location" --ssh-key "$key" --firewall "$box" \
    --user-data-from-file "$here/cloud-init.yaml" >/dev/null

  # A new server can have an address an old one had.
  address=$(hcloud server ip "$box")
  ssh-keygen -R "$address" >/dev/null 2>&1 || true
  ssh-keygen -R "[$address]:2222" >/dev/null 2>&1 || true
fi

address=$(hcloud server ip "$box")
ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o LogLevel=ERROR)
[ -f "${public_key%.pub}" ] && ssh_opts+=(-i "${public_key%.pub}")

remote() { ssh "${ssh_opts[@]}" "$@"; }

say "Waiting for $address to answer SSH"
for _ in $(seq 60); do
  remote "root@$address" true 2>/dev/null && break
  sleep 5
done
remote "root@$address" true || die "$address did not answer SSH within five minutes"

# cloud-init answers 2 for a run that finished with warnings, such as a key it
# has deprecated, and 1 for one that failed.
say "Waiting for cloud-init to finish"
code=0
remote "root@$address" cloud-init status --wait >/dev/null || code=$?

case "$code" in
  0) ;;
  2) say "cloud-init finished with warnings; ssh root@$address cloud-init status --long" ;;
  *) die "cloud-init did not finish; ssh root@$address cat /var/log/cloud-init-output.log" ;;
esac

remote "wardrik@$address" true 2>/dev/null ||
  die "the key did not reach the wardrik user; ssh root@$address cat /var/log/cloud-init-output.log"

# -- the release and the keys ------------------------------------------------------

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

run=$(gh run list --repo "$repo" --branch main --workflow CI --status success --limit 1 \
  --json databaseId --jq '.[0].databaseId')
[ -n "$run" ] || die "no CI run on main has succeeded"

say "Downloading the release CI built in run $run"
gh run download "$run" --repo "$repo" --pattern 'wardrik-*-linux-x86_64.tar.gz' --dir "$work"
tarball=$(find "$work" -type f -name 'wardrik-*-linux-x86_64.tar.gz' | head -n 1)
[ -n "$tarball" ] || die "run $run has no release tarball"

(
  umask 077
  grep -v '^SLACK_CHANNEL=' "$env_file" || true
  echo "SLACK_CHANNEL=$channel"
) >"$work/env"

say "Installing $(basename "$tarball") and the keys, and starting a, b and c"
scp -q "${ssh_opts[@]}" "$tarball" "$work/env" "wardrik@$address:"
remote "wardrik@$address" "
  set -e
  systemctl --user stop wardrik@a wardrik@b wardrik@c 2>/dev/null || true
  tar -xzf $(basename "$tarball") -C ~/wardrik
  rm $(basename "$tarball")
  install -m 600 env ~/.config/wardrik/env
  rm env
  systemctl --user enable --now wardrik@a wardrik@b wardrik@c
"

say "Waiting for the cluster"
for _ in $(seq 30); do
  status=$(remote "wardrik@$address" wardrik/bin/wardrik status 2>&1) || true
  case "$status" in *"cluster of 3: a, b, c up"*) break ;; esac
  sleep 2
done

printf '\n%s\n\n' "$status"

cat <<EOF
$box is at $address.

  ssh -p 2222 jon@$address                            the TUI
  ssh wardrik@$address wardrik/bin/wardrik parked              what waits on a person
  ssh wardrik@$address 'wardrik/bin/wardrik ask _/jon/triage "Open an issue titled Rehearsal check."'
  ssh wardrik@$address 'journalctl --user -u wardrik@a -n 40 --no-pager'

deploy/hetzner/teardown.sh deletes it.
EOF
