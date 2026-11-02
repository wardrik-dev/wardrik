---
title: Upgrade and back up
description: "Install a new release beside the old one, go back if you need to, and back up what the daemon can't make again."
sidebar:
  order: 7
---

## Upgrade

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik_daemon/releases/download/v0.1.0-rc.2/install.sh | sh
systemctl --user restart wardrik
wardrik version
```

- Without `WARDRIK_VERSION`, it installs the newest release, pre-releases included.
- The new release installs beside the old one. A running daemon keeps its release until it
  restarts.
- To go back, run the script with `WARDRIK_VERSION` set to the previous release, and restart.

In Docker, start a new container on the same volumes:

```sh
docker pull ghcr.io/wardrik-dev/wardrik:0.1.0-rc.2
docker rm -f wardrik
docker run -d --name wardrik -p 127.0.0.1:4747:4747 \
  -v wardrik-config:/config -v wardrik:/data ghcr.io/wardrik-dev/wardrik:0.1.0-rc.2
```

## Back up

| What | Where |
| --- | --- |
| What you write | `~/.config/wardrik`: `config.yaml`, `agents/`, `policies/`, `env` |
| The vault's key | `~/.local/share/wardrik/vault_key`, or wherever you keep `WARDRIK_VAULT_KEY` |
| The store | `~/.local/share/wardrik/store`, or the Postgres database |

Keep the vault's key apart from the store's backups. Together they open every secret.

A store on disk:

```sh
wardrik stop
tar -czf wardrik-store-$(date +%F).tar.gz -C ~/.local/share/wardrik store
wardrik start
```

To restore, stop the daemon, put the copy back, and start it. Back up Postgres with `pg_dump`.

## Details

- The script checks the release against its `SHA256SUMS`. It keeps one release before, and
  removes older ones.
- The daemon makes the cookie and the `wardrik` command's token again as it starts.
- An agent a new release can't read starts again from its definition, with an empty conversation.
- `~/.config/wardrik` can live in a dotfiles repository. Leave `env` out: it holds keys.
