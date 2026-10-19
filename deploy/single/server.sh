#!/usr/bin/env bash
#
# The root part of deploy/single/up.sh, run on the server: the user the daemon
# runs as, let in by the keys root's login was, with a systemd of its own from
# boot; and Caddy, ending TLS for the domain given and passing on to the
# daemon's HTTP API /oauth/, where a browser comes back to after a sign-in,
# /v1/hooks/ for its webhook triggers and /v1/channels/ for its channels, and
# nothing else of it. Run again, it changes only what differs.
#
#   bash server.sh agents.example.com
set -euo pipefail

domain=$1
caddyfile=/etc/caddy/Caddyfile
marker="# Written by deploy/single/up.sh"

say() { printf '    %s\n' "$*"; }
die() { printf 'server: %s\n' "$*" >&2; exit 1; }

command -v apt-get >/dev/null || die "this server has no apt-get; it is meant for Ubuntu 24.04 or Debian 12"
command -v systemctl >/dev/null || die "this server has no systemd"

if ! id wardrik >/dev/null 2>&1; then
  say "Making the user wardrik"
  useradd --create-home --shell /bin/bash wardrik
fi

# The keys that let this login in let a person in as wardrik too, added to
# any it has.
home=$(getent passwd wardrik | cut -d: -f6)
keys=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)/.ssh/authorized_keys
install -d -m 700 -o wardrik -g wardrik "$home/.ssh"
touch "$home/.ssh/authorized_keys"
if [ -f "$keys" ]; then
  while IFS= read -r key; do
    [ -z "$key" ] || grep -qxF "$key" "$home/.ssh/authorized_keys" || echo "$key" >>"$home/.ssh/authorized_keys"
  done <"$keys"
fi
chown wardrik:wardrik "$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"

# wardrik's systemd runs from boot, not only while someone is logged in.
loginctl enable-linger wardrik

missing=()
for package in ca-certificates openssl caddy; do
  dpkg -s "$package" >/dev/null 2>&1 || missing+=("$package")
done
if [ "${#missing[@]}" -gt 0 ]; then
  say "Installing ${missing[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null ||
    die "cannot install ${missing[*]}; this Linux's packages may have no caddy, which Ubuntu 24.04 and Debian 12 have"
fi

# The Caddyfile is this script's. One it did not write is kept beside it once.
if [ -f "$caddyfile" ] && ! grep -qF "$marker" "$caddyfile"; then
  [ -e "$caddyfile.before-wardrik" ] || cp "$caddyfile" "$caddyfile.before-wardrik"
fi

cat >"$caddyfile.new" <<EOF
$marker for $domain; it writes this file again each time.

$domain {
	@daemon path /oauth/* /v1/hooks/* /v1/channels/*

	handle @daemon {
		reverse_proxy 127.0.0.1:4747
	}

	handle {
		respond 404
	}
}
EOF

caddy validate --adapter caddyfile --config "$caddyfile.new" >/dev/null 2>&1 ||
  die "Caddy refuses the Caddyfile for $domain: caddy validate --config $caddyfile.new"

if ! cmp -s "$caddyfile.new" "$caddyfile"; then
  mv "$caddyfile.new" "$caddyfile"
  systemctl enable --quiet caddy
  systemctl reload-or-restart caddy
  say "Caddy serves $domain/oauth/"
else
  rm "$caddyfile.new"
  systemctl enable --now --quiet caddy
fi

if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null
  ufw allow 443/tcp >/dev/null
fi
