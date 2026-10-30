---
title: Storage
description: "Keep agents, events, files and secrets on the daemon's own disk, or in Postgres."
sidebar:
  order: 1
---

The daemon keeps everything in one store: agents and conversations, triggers, events, files, the
ledger, tokens and sealed credentials. `storage` in `config.yaml` says where.

| Store | Where it lives | Pick it when |
| --- | --- | --- |
| On disk, the default | SQLite under `~/.local/share/wardrik/store` | one machine you back up |
| Postgres | one table, `wardrik_store` | the store should outlive the machine |

The daemon reads `storage` as it starts. `wardrik doctor` checks it, running or not.

## On disk

Leave `storage` out. The store is SQLite under `~/.local/share/wardrik/store`. `WARDRIK_DATA_DIR`
moves it.

Back it up as [Upgrade and back up](/run/upgrade-and-back-up/#a-store-on-disk) shows.

## In Postgres

```yaml title="~/.config/wardrik/config.yaml"
storage:
  postgres:
    url: ${DATABASE_URL}    # postgres://user:pass@host/db
```

- The daemon creates its table as it starts.
- Point it at the primary. The daemon reads what it just wrote, and a replica may not have it yet.
- Add `?ssl=true` to the URL for TLS. The certificate is checked against the system's.
- `${NAME}` in `storage` comes from the environment or the env file, never the vault, since the
  vault lives in the store.

## Move to a new machine

On Postgres, the store isn't on the daemon's disk. Point a new machine at the same database and
it carries on with its agents.

The vault's key is still on the old machine. Give the new one the same key, or it can't read the
credentials the old one sealed. Do one of:

- Copy `~/.local/share/wardrik/vault_key` across.
- Set the same `WARDRIK_VAULT_KEY` in the new machine's env file.
- List the key under `vault.keys` in `config.yaml`.

There's no tool to move a store from disk to Postgres, or back.

## Details

### What `wardrik doctor` checks

```
ok    storage        keeps everything in Postgres at db.internal:5432/wardrik
```

For Postgres, it checks that the host answers on its port. It doesn't log in. For the disk, it
names the directory.

### Postgres tables

| Table | Holds |
| --- | --- |
| `wardrik_store` | every record, as `key`, `value` and `vsn` |
| `wardrik_store_migrations` | the migrations the daemon has run on it |

The daemon connects with a pool of its own.

### Buckets

The daemon doesn't keep its store in a bucket. It refuses `storage.s3` as it starts.
