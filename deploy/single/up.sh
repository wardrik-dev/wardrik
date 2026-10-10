#!/usr/bin/env bash
#
# Puts one customer's daemon on a server of its own, from this checkout: builds
# the release here, in the Dockerfile's tarball stage, so it runs on the
# server's older glibc, installs it there with deploy/install.sh as a user of
# its own, runs it under that user's systemd, and puts Caddy in front of it for
# the address people's browsers come back to when they connect an account.
#
#   WARDRIK_HOST=root@203.0.113.7 WARDRIK_DOMAIN=acme.example.com \
#   WARDRIK_ENV_FILE=~/customers/acme/env deploy/single/up.sh
#
# Each customer has a server rented for them, a subdomain of a domain of yours
# pointing at it, and an env file of its own here. The server is any Ubuntu
# 24.04 or Debian 12 machine SSH reaches, as root or as a user sudo lets do
# anything without a password, with ports 22, 80 and 443 open to it. Run again, it builds the
# release again and puts it in place, keeping the store, the vault and the
# config the server has.
#
#   WARDRIK_HOST           the server, as ssh names it: root@203.0.113.7
#   WARDRIK_DOMAIN         the customer's subdomain, which Caddy gets a certificate for
#   WARDRIK_ENV_FILE       the customer's env file: SLACK_BOT_TOKEN, SLACK_APP_TOKEN and
#                          the model's key. It replaces the server's on every run.
#   WARDRIK_TARBALL        a release tarball to install, rather than building one
#   WARDRIK_SSH_OPTS       more options for ssh and scp, as -o options both take:
#                          "-o Port=2200 -o IdentityFile=~/.ssh/acme"
#
# These write config.yaml the first time, and are not read again; after that,
# config.yaml on the server is the one to change:
#
#   WARDRIK_ORG            the deployment's org, such as acme; default otherwise
#   WARDRIK_MODEL          the agents' model, anthropic:claude-sonnet-5
#   WARDRIK_APPROVERS      who approves what a Slack thread waits on, comma-separated
#                          @handles, emails or member IDs; anyone in the channel without
#
# The daemon runs as the user wardrik, which the keys that let you in as
# WARDRIK_HOST let in too: ssh wardrik@SERVER, then wardrik status.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd -P)
root=$(cd "$here/../.." && pwd -P)

say() { printf '==> %s\n' "$*"; }
die() { printf 'up: %s\n' "$*" >&2; exit 1; }

host=${WARDRIK_HOST:-}
domain=${WARDRIK_DOMAIN:-}
env_file=${WARDRIK_ENV_FILE:-}
tarball=${WARDRIK_TARBALL:-}
org=${WARDRIK_ORG:-}
model=${WARDRIK_MODEL:-anthropic:claude-sonnet-5}
approvers=${WARDRIK_APPROVERS:-}

[ -n "$host" ] || die "set WARDRIK_HOST to the server, as ssh names it: root@203.0.113.7"
[ -n "$domain" ] || die "set WARDRIK_DOMAIN to the name pointing at the server"
[ -n "$env_file" ] || die "set WARDRIK_ENV_FILE to the customer's env file"
[ -f "$env_file" ] || die "there is no env file at $env_file"
for name in SLACK_BOT_TOKEN SLACK_APP_TOKEN; do
  grep -q "^$name=." "$env_file" || die "$env_file has no $name; see the Slack app in docs/src/content/docs/channels/slack.md"
done
[ -z "$tarball" ] || [ -f "$tarball" ] || die "there is no tarball at $tarball"

for command in ssh scp sha256sum; do
  command -v "$command" >/dev/null || die "needs $command"
done
[ -n "$tarball" ] || command -v docker >/dev/null || die "needs docker to build the release, or WARDRIK_TARBALL"

ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o LogLevel=ERROR)
read -ra more <<<"${WARDRIK_SSH_OPTS:-}"
ssh_opts+=("${more[@]}")
server=${host#*@}
remote() { ssh "${ssh_opts[@]}" "$@"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# -- the server ---------------------------------------------------------------

say "Reading $host"
remote "$host" true || die "cannot reach $host over SSH"
arch=$(remote "$host" uname -m)
case "$arch" in
  x86_64) platform=amd64 ;;
  aarch64) platform=arm64 ;;
  *) die "$host is $arch; the release runs on x86_64 and aarch64" ;;
esac

if [ "$(remote "$host" id -u)" = 0 ]; then
  as_root=(bash -s)
elif remote "$host" sudo -n true 2>/dev/null; then
  as_root=(sudo -n bash -s)
else
  die "$host is neither root nor a user sudo lets in without a password"
fi

say "Making the user wardrik, and Caddy in front of the daemon for $domain"
remote "$host" "${as_root[@]}" -- "$domain" <"$here/server.sh"

remote "wardrik@$server" true 2>/dev/null ||
  die "the keys that let you in as $host did not let you in as wardrik@$server"

# -- the release --------------------------------------------------------------

version=$(sed -n 's/^ *version: "\(.*\)",$/\1/p' "$root/release/mix.exs")
name="wardrik-$version-linux-$arch.tar.gz"

if [ -n "$tarball" ]; then
  cp "$tarball" "$work/$name"
else
  say "Building the $arch release $version from $root"
  docker buildx build --platform "linux/$platform" --target tarball \
    --output "type=local,dest=$work/dist" "$root"
  mv "$work/dist/wardrikd-$version.tar.gz" "$work/$name"
fi
(cd "$work" && sha256sum "$name" >SHA256SUMS)

# -- what the daemon reads ----------------------------------------------------

mkdir -p "$work/config"
cp -R "$here/agents" "$here/policies" "$work/config/"
(umask 077 && cp "$env_file" "$work/env")

{
  echo "# Written once by deploy/single/up.sh, which never writes it again: change it here,"
  echo "# then systemctl --user restart wardrik. See the docs' config.yaml reference."
  [ -z "$org" ] || printf '\norg: %s\n' "$org"
  cat <<EOF

defaults:
  model: $model
  policy: careful

# Caddy passes $domain/oauth/ on to the daemon, where a browser comes back to
# when someone connects an account. The daemon listens for it once a provider
# is named: each account the agents' MCP servers sign in with.
oauth:
  redirect:
    url: https://$domain/oauth
  # providers:
  #   shop:
  #     resource: https://mcp.example.com/mcp

channels:
  slack:
    type: slack
    token: \${SLACK_BOT_TOKEN}
    app_token: \${SLACK_APP_TOKEN}
EOF
  if [ -n "$approvers" ]; then
    printf '    approvers: ['
    IFS=, read -ra people <<<"$approvers"
    for i in "${!people[@]}"; do
      person=$(echo "${people[$i]}" | xargs)
      [ "$i" = 0 ] || printf ', '
      printf '"%s"' "$person"
    done
    printf ']\n'
  fi
} >"$work/config/config.yaml"

# -- install and start --------------------------------------------------------

say "Installing $name on $server, as wardrik"
remote "wardrik@$server" 'rm -rf ~/.deploy && mkdir -m 700 ~/.deploy'
scp -q -r "${ssh_opts[@]}" "$root/deploy/install.sh" "$work/$name" "$work/SHA256SUMS" \
  "$work/env" "$work/config" "wardrik@$server:.deploy/"
remote "wardrik@$server" bash -s -- "$name" <"$here/user.sh"

cat <<EOF

The daemon runs on $server, as wardrik, behind https://$domain/oauth.

  ssh wardrik@$server .local/bin/wardrik status     what runs
  ssh wardrik@$server .local/bin/wardrik doctor     what it reads, and whether $domain reaches it
  ssh wardrik@$server .local/bin/wardrik logs       its log

Invite the Slack app to a channel to have the agent answer there. Run this again to put a new
release in place.
EOF
