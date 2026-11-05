---
title: Storage
description: "Store agents, events, files and secrets on the daemon's local disk, in Postgres, or in an S3 bucket."
sidebar:
  order: 1
---

The daemon persists all state in one store: agents, conversations, triggers, events, files, tokens
and encrypted secrets.

| Store | Location | Use for |
| --- | --- | --- |
| On disk, the default | `~/.local/share/wardrik/store` | one machine, or a cluster with a quorum |
| Postgres | one table, `wardrik_store` | state that survives the machines |
| S3 | one object per key, in a bucket | state that survives the machines, with no database |

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

## In S3

```yaml title="~/.config/wardrik/config.yaml"
storage:
  s3:
    bucket: wardrik
    endpoint: https://s3.us-east-1.amazonaws.com
    access_key_id: ${S3_ACCESS_KEY_ID}
    secret_access_key: ${S3_SECRET_ACCESS_KEY}
```

- Works with AWS S3, Cloudflare R2, Tigris and MinIO. R2 takes `region: auto`.
- The bucket must exist. On startup the daemon checks it refuses a conditional write that fails,
  and won't start on one that doesn't.
- Where a bucket ignores the version on a delete, as MinIO does, a delete writes an empty object
  that reads as nothing.
- Every read is a request, so it's slower than disk or Postgres.
- On Tigris, add `headers: {x-tigris-consistent: "true"}`.
- `${NAME}` here resolves from the environment or the env file, not the vault.

## Move to a new machine

On Postgres or S3, configure the new machine with the same database URL or bucket. It also needs the same vault
key to decrypt existing secrets:

- copy `~/.local/share/wardrik/vault_key`, or
- set the same `WARDRIK_VAULT_KEY`, or
- list the key under `vault.keys`.

There's no migration from a disk store to Postgres.

## Details

- `wardrik doctor` checks that the Postgres host or the S3 endpoint is reachable. It doesn't
  authenticate.
- `WARDRIK_DATA_DIR` sets the disk store's path.
