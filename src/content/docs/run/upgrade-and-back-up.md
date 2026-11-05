---
title: Upgrade and back up
description: "Install a new release next to the old one, roll back, and back up the files and store."
sidebar:
  order: 8
---

## Upgrade

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik_daemon/releases/download/v0.1.0-rc.7/install.sh | sh
systemctl --user restart wardrik
wardrik version
```

- Without `WARDRIK_VERSION`, it installs the latest release, including pre-releases.
- The new release installs next to the old one. A running daemon uses its release until restarted.
- To roll back, run the script with `WARDRIK_VERSION` set to the previous release, and restart.

In Docker, start a new container with the same volumes:

```sh
docker pull ghcr.io/wardrik-dev/wardrik:0.1.0-rc.7
docker rm -f wardrik
docker run -d --name wardrik -p 127.0.0.1:4747:4747 \
  -v wardrik-config:/config -v wardrik:/data ghcr.io/wardrik-dev/wardrik:0.1.0-rc.7
```

## Back up

| What | Where |
| --- | --- |
| Your files | `~/.config/wardrik`: `config.yaml`, `agents/`, `policies/`, `env` |
| The vault key | `~/.local/share/wardrik/vault_key`, or wherever `WARDRIK_VAULT_KEY` is stored |
| The store | `~/.local/share/wardrik/store`, the Postgres database, or the S3 bucket |

Back up the vault key separately from the store. Together they decrypt every secret.

A store on disk:

```sh
wardrik stop
tar -czf wardrik-store-$(date +%F).tar.gz -C ~/.local/share/wardrik store
wardrik start
```

To restore, stop the daemon, extract the archive, and start it. Back up Postgres with `pg_dump`, and a bucket with your provider's versioning or replication.

## Details

- The script verifies the release against its `SHA256SUMS`. It keeps the previous release and
  removes older ones.
- The daemon regenerates the cookie and the `wardrik` command's token on startup.
- If a new release can't read an agent's state, the agent restarts from its definition with an
  empty conversation.
- `~/.config/wardrik` can be kept in a dotfiles repository. Exclude `env`, which contains keys.
