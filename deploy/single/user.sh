#!/usr/bin/env bash
#
# The wardrik user's part of deploy/single/up.sh, run on the server from
# ~/.deploy, which up.sh fills: installs the release tarball named, puts the
# env file in place, writes config.yaml and the example agent and policy where
# there are none, gives the vault a key where it has none, and runs the daemon
# under systemd, started again on the new release.
#
#   bash user.sh wardrik-0.1.0-linux-x86_64.tar.gz
set -euo pipefail

tarball=$1
incoming=$HOME/.deploy
config=${XDG_CONFIG_HOME:-$HOME/.config}/wardrik
data=${XDG_DATA_HOME:-$HOME/.local/share}/wardrik
wardrik=$HOME/.local/bin/wardrik

say() { printf '    %s\n' "$*"; }

cd "$incoming"
sh install.sh "$tarball" | sed 's/^/    /'

install -d -m 700 "$config" "$data"
install -m 600 env "$config/env"

[ -e "$config/config.yaml" ] || install -m 644 config/config.yaml "$config/config.yaml"
for dir in agents policies; do
  install -d "$config/$dir"
  for file in config/"$dir"/*; do
    [ -e "$config/$dir/$(basename "$file")" ] || install -m 644 "$file" "$config/$dir/"
  done
done

# The vault seals the accounts people connect. Its key stays on the server,
# beside the store, unless the env file gives it one.
if ! grep -q '^WARDRIK_VAULT_KEY=.' "$config/env" && [ ! -s "$data/vault_key" ]; then
  say "Making the vault's key, in $data/vault_key"
  (umask 077 && openssl rand -base64 32 >"$data/vault_key")
fi

if systemctl --user cat wardrik.service >/dev/null 2>&1; then
  say "Starting the daemon again, on the new release"
  systemctl --user restart wardrik.service
else
  "$wardrik" service install | sed 's/^/    /'
fi

for _ in $(seq 30); do
  "$wardrik" status >/dev/null 2>&1 && break
  sleep 2
done

"$wardrik" status | sed 's/^/    /'
echo
"$wardrik" doctor | sed 's/^/    /' || true

cd && rm -rf "$incoming"
