---
title: Storage
description: "Store agents, events, files and secrets on the daemon's local disk, or in Postgres."
sidebar:
  order: 1
---

The daemon persists all state in one store: agents, conversations, triggers, events, files, tokens
and encrypted secrets.

| Store | Location | Use for |
| --- | --- | --- |
| On disk, the default | `~/.local/share/wardrik/store` | one machine, with backups |
| Postgres | one table, `wardrik_store` | state that survives the machine |

## In Postgres

```yaml title="~/.config/wardrik/config.yaml"
storage:
  postgres:
    url: ${DATABASE_URL}    # postgres://user:pass@host/db
```

- The daemon creates its table on startup.
- Use the primary, not a replica.
- Add `?ssl=true` for TLS.
- `${NAME}` here resolves from the environment or the env file, not the vault.

## Move to a new machine

On Postgres, configure the new machine with the same database URL. It also needs the same vault
key to decrypt existing secrets:

- copy `~/.local/share/wardrik/vault_key`, or
- set the same `WARDRIK_VAULT_KEY`, or
- list the key under `vault.keys`.

There's no migration from a disk store to Postgres.

## Details

- `wardrik doctor` checks that the Postgres host is reachable. It doesn't authenticate.
- `WARDRIK_DATA_DIR` sets the disk store's path.
- The daemon rejects `storage.s3`.
