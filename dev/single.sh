#!/usr/bin/env bash
# shellcheck disable=SC2016 # the scripts in single quotes are expanded on the server
#
# Runs deploy/single/up.sh against a container standing in for a customer's
# server, and checks what it leaves: the daemon running as wardrik under
# systemd, Caddy passing /oauth/ on to it, config.yaml as up.sh writes it, the
# vault's key; then, run again, that it keeps the config, the key and the
# vault's secrets, and runs again after the server restarts.
#
#   docker build --target tarball --output type=local,dest=dist .
#   dev/single.sh dist/wardrikd-0.1.0.tar.gz
#
# The container runs systemd and sshd on Ubuntu 24.04, from an image built
# here for this machine's architecture, and lets root in with a key made for
# the run. It is privileged, as systemd needs, and removed at the end. Caddy's
# certificate is its own, for localhost, as no certificate authority answers
# for a container.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd -P)
[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: dev/single.sh TARBALL" >&2; exit 1; }
image=wardrik-server:24.04
box=wardrik-single-$$

say() { printf '==> %s\n' "$*"; }
die() { printf 'single: %s\n' "$*" >&2; exit 1; }

work=$(mktemp -d)
trap 'docker rm -f "$box" > /dev/null 2>&1 || true; rm -rf "$work"' EXIT

docker build -q -t "$image" - > /dev/null << 'IMAGE'
FROM ubuntu:24.04
RUN apt-get update \
  && apt-get install -y --no-install-recommends systemd systemd-sysv dbus dbus-user-session \
    libpam-systemd openssh-server curl \
  && rm -rf /var/lib/apt/lists/* \
  && systemctl enable ssh
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
IMAGE

docker run -d --name "$box" --privileged --cgroupns=host -p 127.0.0.1::22 \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw "$image" > /dev/null
port=$(docker port "$box" 22/tcp | head -n 1 | sed 's/.*://')

ssh-keygen -q -t ed25519 -N "" -f "$work/key"
docker exec "$box" sh -c 'install -d -m 700 /root/.ssh'
docker cp "$work/key.pub" "$box:/root/.ssh/authorized_keys"
docker exec "$box" sh -c 'chown root:root /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'

ssh_opts="-o Port=$port -o IdentityFile=$work/key -o IdentitiesOnly=yes -o UserKnownHostsFile=$work/known_hosts"
read -ra opts <<< "$ssh_opts -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"
on_server() { ssh "${opts[@]}" "wardrik@127.0.0.1" "$@"; }

cat > "$work/env" << 'ENV'
SLACK_BOT_TOKEN=xoxb-not-a-token
SLACK_APP_TOKEN=xapp-not-a-token
ENV

up() {
  WARDRIK_HOST=root@127.0.0.1 WARDRIK_DOMAIN=localhost WARDRIK_ENV_FILE="$work/env" \
    WARDRIK_TARBALL="$1" WARDRIK_SSH_OPTS="$ssh_opts" WARDRIK_ORG=acme \
    WARDRIK_APPROVERS="${2:-}" "$repo/deploy/single/up.sh"
}

answers() {
  on_server 'for _ in $(seq 60); do .local/bin/wardrik status > /dev/null 2>&1 && exit 0; sleep 1; done; exit 1' ||
    die "the daemon did not answer"
}

docker exec "$box" sh -c 'until systemctl is-system-running 2> /dev/null | grep -qE "running|degraded"; do sleep 1; done'

say "puts the daemon on the server"
up "$1" "@maria, jon@example.com"
answers
on_server 'systemctl --user is-active --quiet wardrik.service' || die "the daemon is not wardrik's service"
on_server '.local/bin/wardrik status' | grep -q "acme/assistant" || die "the example agent does not run"
on_server 'grep -qxF "    approvers: [\"@maria\", \"jon@example.com\"]" .config/wardrik/config.yaml' ||
  die "config.yaml does not name the approvers"
on_server 'grep -qxF "    url: https://localhost/oauth" .config/wardrik/config.yaml' ||
  die "config.yaml does not give the callback's address"
on_server '[ "$(stat -c %a .local/share/wardrik/vault_key)" = 600 ] && [ "$(stat -c %a .config/wardrik/env)" = 600 ]' ||
  die "the vault's key or the env file can be read by others"

say "serves the callback, and nothing else, through Caddy, once a provider is named"
on_server 'sed -i "s/^  # providers:/  providers:/; s/^  #   shop:/    shop:/; s|^  #     resource:|      resource:|" .config/wardrik/config.yaml'
on_server 'systemctl --user restart wardrik.service'
answers
docker exec "$box" sh -c 'for _ in $(seq 30); do
    curl -fsSk "https://localhost/oauth/check?nonce=abc" | grep -qx "wardrik abc" && exit 0; sleep 1
  done; exit 1' || die "https://localhost/oauth/check did not reach the daemon"
status=$(docker exec "$box" curl -sSk -o /dev/null -w '%{http_code}' https://localhost/)
[ "$status" = 404 ] || die "https://localhost/ answered $status, not 404"

say "keeps the config, the vault's key and its secrets when run again"
key=$(on_server 'cat .local/share/wardrik/vault_key')
on_server 'echo "# kept" >> .config/wardrik/config.yaml'
on_server 'printf s3cret | .local/bin/wardrik vault put KEPT --yes > /dev/null'
up "$1" "@someone-else"
answers
[ "$(on_server 'cat .local/share/wardrik/vault_key')" = "$key" ] || die "the vault's key changed"
on_server 'tail -n 1 .config/wardrik/config.yaml | grep -qx "# kept"' || die "config.yaml was written again"
on_server '.local/bin/wardrik vault ls' | grep -q KEPT || die "the vault lost its secret"

say "runs again after the server restarts"
docker restart "$box" > /dev/null
docker exec "$box" sh -c 'until systemctl is-system-running 2> /dev/null | grep -qE "running|degraded"; do sleep 1; done'
docker exec "$box" systemctl start systemd-logind
# A restarted container may publish SSH on another port, so this asks inside it.
docker exec -u wardrik -w /home/wardrik "$box" sh -c \
  'for _ in $(seq 60); do .local/bin/wardrik status > /dev/null 2>&1 && exit 0; sleep 1; done; exit 1' ||
  die "the daemon did not run again after the restart"

say "The deploy did what it should"
