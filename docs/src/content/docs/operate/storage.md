---
title: Storage
description: Where the daemon keeps agents, events, files and secrets, on its own disk, in Postgres or in an S3 bucket.
sidebar:
  order: 1
---

Everything the daemon keeps is in one store: agents and their conversations, schedules, the event
log, agents' files, the ledger, tokens, sealed credentials, and the tools MCP servers listed. Where
the store is decides what a node needs to carry on.

| Store | Kept | A cluster needs |
| --- | --- | --- |
| On disk, the default | on each node, replicated to the others | more than half of its nodes up |
| Postgres | in one table | the database |
| An S3 bucket | under one prefix | the bucket |

`storage` in `config.yaml` names the store, and is read as the daemon starts, before anything else.
`wardrik doctor` checks it, running or not.

## On disk

Without `storage`, the store is on the node's disk, under `~/.local/share/wardrik/store`, or
`WARDRIK_DATA_DIR`. It is SQLite underneath.

In a cluster, every node holds everything, and a write is made once more than half of the nodes
have it. So three nodes carry on with one lost, and two stop when either is. A node starting waits
until enough of the others are up. See [Run a cluster](/operate/cluster/).

## Postgres

```yaml title="~/.config/wardrik/config.yaml"
storage:
  postgres:
    url: ${DATABASE_URL}    # postgres://user:pass@host/db
```

The daemon connects with a pool of its own, and creates its table, `wardrik_records`, as it starts,
recording the migration in `wardrik_schema_migrations`. `?ssl=true` on the URL connects with TLS,
checked against the system's certificates.

Name the primary: the daemon reads what it writes, and a replica may not have it yet.

## An S3 bucket

```yaml title="~/.config/wardrik/config.yaml"
storage:
  s3:
    bucket: wardrik
    endpoint: https://<account>.r2.cloudflarestorage.com
    region: auto
    access_key_id: ${R2_ACCESS_KEY_ID}
    secret_access_key: ${R2_SECRET_ACCESS_KEY}
```

`region` is `us-east-1` unless set, and everything is kept under `wardrik/`, or `prefix`. Requests
are made path-style, to `endpoint/bucket/key`.

The daemon keeps nothing in a bucket that does not refuse a write whose condition fails, since two
nodes writing the same record would lose one of the writes. As it starts, it writes a probe under
`wardrik/probe/` and checks that the bucket refuses to write over it without its current version.
A bucket that does not is refused with what it did:

```
the bucket wardrik at https://...: the bucket wrote a key where one was already written, so it cannot hold the store
```

Cloudflare R2 and MinIO pass. A bucket that ignores the condition on a delete, as MinIO does, is
used with deletes written as empty records, which stay in the bucket.

## What is kept where

Each kind of record has a namespace of its own:

| Namespace | What |
| --- | --- |
| `durable` | agents, as `agents/<org>/<user>/<name>`; schedules; budget meters; each node's heartbeat |
| `events` | each agent's event log, for 30 days |
| `files` | agents' files, as `<tree>//<path>` |
| `claims` | the ledger, until each turn ends |
| `tokens` | the HTTP API's tokens, as hashes |
| `vault` | sealed credentials |
| `mcp_tools` | the tools each MCP server listed |
| `oauth_clients` | the clients the daemon registered with OAuth providers |

In a bucket, a record is the object `<prefix>/<namespace>/<key>`, so an agent is
`wardrik/durable/agents/acme/jon/triage`. In Postgres, `ns` is the namespace and `key` the key.

## Moving

A daemon on Postgres or a bucket keeps nothing of the store on its disk, so a new machine pointed at
the same store carries on with its agents.

There is no tool for moving a store from one kind to another.
