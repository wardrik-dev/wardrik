---
title: Upgrade and back up
description: "Install a new release beside the old one, go back if you need to, and back up what the daemon can't make again."
sidebar:
  order: 7
---

A new release installs beside the old one, so going back is one command. Back up what you wrote,
the vault's key and the store; the daemon makes the rest again.

## Upgrade

Run the install script again, then restart:

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | sh
systemctl --user restart wardrik    # or: wardrik stop && wardrik start
```

A running daemon keeps its release until it restarts. To install a particular release, set
`WARDRIK_VERSION`:

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | WARDRIK_VERSION=0.1.0 sh
```

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

Images are tagged with each version and `latest`; `ghcr.io/wardrik-dev/wardrik:0.1.0` stays on one.

## Back up

| What | Where | Why |
| --- | --- | --- |
| What you write | `~/.config/wardrik`: `config.yaml`, `agents/`, `policies/`, `ssh/authorized_keys`, `env` | the daemon only reads it |
| The vault's key | `~/.local/share/wardrik/vault_key`, or wherever you keep `WARDRIK_VAULT_KEY` | without it, sealed credentials can't be read |
| The store | `~/.local/share/wardrik/store`, or the database or bucket `storage` names | agents, conversations, triggers, files, tokens and credentials |
| The cookie | `~/.local/share/wardrik/cookie` | a cluster's nodes need the same one |
| The SSH host key | `~/.local/share/wardrik/ssh` | without it, clients see a changed host key |

Keep the vault's key apart from the store's backups. Together they open every credential.

### A store on disk

Stop the daemon, copy the store, and start it again:

```sh
wardrik stop
tar -czf wardrik-store-$(date +%F).tar.gz -C ~/.local/share/wardrik store
wardrik start
```

To restore, stop the daemon, put the copy back, and start it.

### Postgres or a bucket

The store isn't on the daemon's disk. Back up the database or bucket with its own tools: `pg_dump`,
or the bucket's versioning or replication.

## Details

- The script checks the release against its `SHA256SUMS` and runs it once before installing it.
  It points `current`, and so `wardrik`, at the new release, keeps the one before, and removes older
  ones unless a node still runs from them.
- The service runs `current`, so a restart starts the new release.
- A release can change how it writes agents down, and needs no cleanup when it does. An agent the
  new release can't read starts again from its file or definition. Its conversation starts empty,
  its log is kept, and a turn it had parked on a person is lost.
- Two releases running at once, as in a blue-green deploy, can't read each other's agents. For the
  minute both run, each treats the other's agents as absent.
- `~/.config/wardrik` holds only what a person writes, so it can live in a dotfiles repository.
  Leave `env` out: it holds keys.
- In a cluster, every node holds everything. A copy of one stopped node's store is a copy of the
  cluster's, up to the writes that node had. The others carry on while it's stopped, as long as more
  than half the nodes are up.
- In Docker, the `/data` volume holds the store, the cookie and the host key, and `/config` holds
  whatever you mounted there.
