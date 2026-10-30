---
title: Upgrade and back up
description: "Install a new release beside the old one, go back if you need to, and back up what the daemon can't make again."
sidebar:
  order: 7
---

A new release installs beside the old one, so going back is one command. Back up what you wrote,
the vault's key and the store. The daemon makes the rest again.

## Upgrade

Run the install script again, then restart:

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | sh
systemctl --user restart wardrik    # or: wardrik stop && wardrik start
```

A running daemon keeps its release until it restarts. To install a particular release, set
`WARDRIK_VERSION`:

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | WARDRIK_VERSION=0.1.0-rc.1 sh
```

`wardrik version` prints the release you're running.

## Go back

Run the script with the previous release as `WARDRIK_VERSION`, and restart. If that release is
still installed, it's switched back without unpacking.

## Upgrade in Docker

Pull the new image and start a new container on the same volume:

```sh
docker pull ghcr.io/wardrik-dev/wardrik
docker rm -f wardrik
docker run -d --name wardrik -p 127.0.0.1:4747:4747 -v wardrik:/data ghcr.io/wardrik-dev/wardrik
```

Images are tagged with each version and `latest`. `ghcr.io/wardrik-dev/wardrik:0.1.0-rc.1` stays on
one.

## Back up

| What | Where | Why |
| --- | --- | --- |
| What you write | `~/.config/wardrik`: `config.yaml`, `agents/`, `policies/`, `env` | the daemon only reads it |
| The vault's key | `~/.local/share/wardrik/vault_key`, or wherever you keep `WARDRIK_VAULT_KEY` | without it, sealed credentials can't be read |
| The store | `~/.local/share/wardrik/store`, or the database `storage` names | agents, conversations, triggers, files, tokens and credentials |

Keep the vault's key apart from the store's backups. Together they open every credential.

The daemon makes the rest again as it starts: the cookie, and the `wardrik` command's token.

### A store on disk

```sh
# 1. Stop the daemon, so the store is still.
wardrik stop

# 2. Copy the store.
tar -czf wardrik-store-$(date +%F).tar.gz -C ~/.local/share/wardrik store

# 3. Start it again.
wardrik start
```

To restore, stop the daemon, put the copy back in `~/.local/share/wardrik/store`, and start it.

### Postgres

The store isn't on the daemon's disk. Back up the database with its own tools, such as `pg_dump`.

## Details

- The script checks the release against its `SHA256SUMS` and runs it once before installing it.
  It points `current`, and so `wardrik`, at the new release. It keeps the one before, and removes
  older ones.
- The service runs `current`, so a restart starts the new release.
- An agent a new release can't read starts again from its file or definition. Its conversation
  starts empty, and a turn it had parked on a person is lost.
- `~/.config/wardrik` holds only what a person writes, so it can live in a dotfiles repository.
  Leave `env` out: it holds keys.
- To rotate the vault's key, list the new key first under `vault.keys`, with the old one after it.
  The first key seals. Any listed key unseals.
