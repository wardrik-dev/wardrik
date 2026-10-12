---
title: Upgrade and back up
description: Install a new release beside the old one, go back to the one before, and keep a copy of what the daemon cannot make again.
sidebar:
  order: 5
---

## Upgrade

Run the install script again:

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | sh
```

It checks the new release against its `SHA256SUMS`, runs it once, and puts it beside the old one,
pointing `current`, and so `wardrik`, at it. It keeps the release before, and removes older ones
unless a node still runs from them.

A daemon already running carries on with the release it started with until it is restarted:

```sh
systemctl --user restart wardrik    # the service runs current, so it starts the new release
wardrik stop && wardrik start       # without the service
```

`WARDRIK_VERSION` installs a release other than the latest:

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | WARDRIK_VERSION=0.1.0 sh
```

### Going back

Run the script with the release before as `WARDRIK_VERSION`, and restart. Where that release is
still installed, it points `current` back at it without unpacking it again.

### In Docker

Pull the new image and start a new container on the same volume, which carries on from the store:

```sh
docker pull ghcr.io/wardrik-dev/wardrik
docker rm -f wardrik
docker run -d --name wardrik -p 127.0.0.1:4747:4747 -v wardrik:/data ghcr.io/wardrik-dev/wardrik
```

Images are tagged with each version and `latest`, so `ghcr.io/wardrik-dev/wardrik:0.1.0` stays on
one.

## Back up

The daemon makes most of what it keeps again, but not these:

| What | Where | Why |
| --- | --- | --- |
| What you write | `~/.config/wardrik`: `config.yaml`, `agents/`, `policies/`, `ssh/authorized_keys`, `env` | the daemon only reads it |
| The vault's key | `~/.local/share/wardrik/vault_key`, or wherever you keep `WARDRIK_VAULT_KEY` | without it, sealed credentials cannot be read |
| The store | `~/.local/share/wardrik/store`, or the database or bucket `storage` names | agents, conversations, triggers, files, tokens and sealed credentials |
| The cookie | `~/.local/share/wardrik/cookie` | a cluster's nodes all need the same one |
| The SSH host key | `~/.local/share/wardrik/ssh` | without it, clients are told the host key changed |

`~/.config/wardrik` is only what a person writes, so it can live in a dotfiles repository, `env`
apart, since it holds keys.

Keep the vault's key apart from the store's backups: together, they open every credential the
daemon holds.

### The store on disk

Stop the daemon, copy the store, and start it again:

```sh
wardrik stop
tar -czf wardrik-store-$(date +%F).tar.gz -C ~/.local/share/wardrik store
wardrik start
```

In a cluster, every node holds a copy of everything, so a copy of one node's store, taken while it
is stopped, is a copy of the cluster's, as far as the writes that node had received. The others
carry on while it is stopped, as long as more than half of the nodes are up.

To restore, stop the daemon, put the copy back in place, and start it.

### Postgres or a bucket

With `storage` in `config.yaml`, the daemon keeps nothing of the store on its disk, and the database
or bucket is what to back up, with its own tools: `pg_dump`, or the bucket's versioning or
replication.

### In Docker

The `/data` volume holds the store, the cookie and the host key, and `/config` what you mounted
there.
