---
title: Storage
description: "Keep agents, events, files and secrets on the daemon's own disk, in Postgres, or in an S3 bucket."
sidebar:
  order: 1
---

The daemon keeps everything in one store: agents and conversations, triggers, events, files, the
ledger, tokens and sealed credentials. Where the store lives decides what a node needs to keep
going.

| Store | Kept | A cluster needs |
| --- | --- | --- |
| On disk, the default | on each node, copied to the others | more than half its nodes up |
| Postgres | in one table | the database |
| An S3 bucket | under one prefix | the bucket |

`storage` in `config.yaml` names the store. It's read as the daemon starts, and `wardrik doctor`
checks it, running or not.

## On disk

Without `storage`, the store is SQLite under `~/.local/share/wardrik/store`, or `WARDRIK_DATA_DIR`.

In a cluster every node holds everything. A write lands once more than half the nodes have it, so
three nodes carry on with one lost, and two stop when either is. See
[Run a cluster](/run/cluster/#quorum).

## In Postgres

```yaml title="~/.config/wardrik/config.yaml"
storage:
  postgres:
    url: ${DATABASE_URL}    # postgres://user:pass@host/db
```

The daemon creates its table as it starts. Point it at the primary: it reads what it just wrote, and
a replica may not have it yet. Add `?ssl=true` to the URL for TLS.

## In an S3 bucket

```yaml title="~/.config/wardrik/config.yaml"
storage:
  s3:
    bucket: wardrik
    endpoint: https://<account>.r2.cloudflarestorage.com
    region: auto
    access_key_id: ${R2_ACCESS_KEY_ID}
    secret_access_key: ${R2_SECRET_ACCESS_KEY}
```

The bucket must refuse a write whose condition fails, or two nodes could lose each other's writes.
The daemon checks this as it starts, and refuses a bucket that doesn't. Cloudflare R2 and MinIO
pass.

## Move to a new machine

On Postgres or a bucket, the daemon keeps nothing of the store on its disk. Point a new machine at
the same store and it carries on with its agents.

There's no tool to move a store from one kind to another.

## Details

### Postgres

The daemon connects with a pool of its own. It creates `wardrik_records` and records the migration
in `wardrik_schema_migrations`. With `?ssl=true` the certificate is checked against the system's.

### Buckets

- `region` is `us-east-1` unless set.
- Everything is kept under `wardrik/`, or `prefix`.
- Requests are path-style, to `endpoint/bucket/key`.
- The start-up check writes a probe under `wardrik/probe/`, and makes sure the bucket refuses to
  overwrite it without its current version. A bucket that fails says what it did:

  ```
  the bucket wardrik at https://...: the bucket wrote a key where one was already written, so it cannot hold the store
  ```

- A bucket that ignores the condition on a delete, as MinIO does, gets deletes written as empty
  records, which stay in the bucket.

### What is kept where

Each kind of record has its own namespace:

| Namespace | What |
| --- | --- |
| `durable` | agents, as `agents/<key>`; triggers; budget meters; each node's heartbeat |
| `events` | each agent's event log, for 30 days |
| `files` | agents' files, as `<tree>//<path>` |
| `claims` | the ledger, until each turn ends |
| `tokens` | the HTTP API's tokens, as hashes |
| `vault` | sealed credentials |
| `mcp_tools` | the tools each MCP server listed |
| `oauth_clients` | the clients the daemon registered with OAuth providers |
| `declared` | each node's inventory: the agents its agent files declared when last read, and which file each came from |

In a bucket a record is the object `<prefix>/<namespace>/<key>`, so an agent is
`wardrik/durable/agents/acme/@jon/triage`. In Postgres, `ns` is the namespace and `key` the key.
