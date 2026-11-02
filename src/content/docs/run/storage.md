---
title: Storage
description: "Keep agents, events, files and secrets on the daemon's own disk, or in Postgres."
sidebar:
  order: 1
---

The daemon keeps everything in one store: agents, conversations, triggers, events, files, tokens
and sealed secrets.

| Store | Where | Pick it when |
| --- | --- | --- |
| On disk, the default | `~/.local/share/wardrik/store` | one machine you back up |
| Postgres | one table, `wardrik_store` | the store should outlive the machine |

## In Postgres

```yaml title="~/.config/wardrik/config.yaml"
storage:
  postgres:
    url: ${DATABASE_URL}    # postgres://user:pass@host/db
```

- The daemon creates its table as it starts.
- Point it at the primary, not a replica.
- Add `?ssl=true` for TLS.
- `${NAME}` here reads the environment or the env file, never the vault.

## Move to a new machine

On Postgres, point the new machine at the same database. Give it the same vault key, or it can't
read the old secrets:

- copy `~/.local/share/wardrik/vault_key`, or
- set the same `WARDRIK_VAULT_KEY`, or
- list the key under `vault.keys`.

There's no tool to move a store from disk to Postgres.

## Details

- `wardrik doctor` checks that Postgres's host answers. It doesn't log in.
- `WARDRIK_DATA_DIR` moves the store on disk.
- The daemon refuses `storage.s3`.
- When embedding Wardrik in your app, see [Embed in your app](/build/embed/) for the store options.
