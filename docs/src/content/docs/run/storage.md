---
title: Storage
description: "Persist agent state on local disk, in Postgres, or in S3."
sidebar:
  order: 1
---

Wardrik saves agents, conversations, triggers, events, files, tokens, and encrypted secrets in
one configured storage backend.

| Store | Location | Use for |
| --- | --- | --- |
| On disk, the default | `~/.local/share/wardrik/store` | one machine, or a cluster with a quorum |
| Postgres | one table, `wardrik_store` | persistent state independent of agent machines |
| S3 | one object per key, in a bucket | persistent state independent of agent machines; no database required |

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
- Create the bucket first. At startup, Wardrik checks that it rejects writes with a failed
  condition. It will not start if the bucket fails this check.
- For backends that ignore version conditions on deletes, such as MinIO, Wardrik writes an empty
  object and treats it as deleted.
- Every read is a request, so it's slower than disk or Postgres.
- On Tigris, add `headers: {x-tigris-consistent: "true"}`.
- `${NAME}` here resolves from the environment or the env file, not the vault.

## Move to a new machine

With Postgres or S3, point the new machine at the existing database or bucket. To decrypt
existing secrets, configure the same vault key:

- copy `~/.local/share/wardrik/vault_key`, or
- set the same `WARDRIK_VAULT_KEY`, or
- list the key under `vault.keys`.

There's no migration from a disk store to Postgres.

## Details

- `wardrik doctor` checks that the Postgres host or the S3 endpoint is reachable. It doesn't
  authenticate.
- `WARDRIK_DATA_DIR` sets the disk store's path.
