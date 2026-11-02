---
title: Run a cluster
description: "The daemon runs as one node. What carries on when its machine is lost."
sidebar:
  order: 2
---

The daemon runs as one node. `wardrik status` lists it:

```text
Wardrik runs at http://127.0.0.1:4747.
NODE               AGENTS
wardrik@localhost  3
2 asleep
```

- It doesn't join nodes into a cluster. A `cluster` key in `config.yaml` is skipped with a warning.
- Keep the store in [Postgres](/run/storage/#in-postgres) and the vault's key off the machine. A new
  machine with the same database and key carries on with every agent.
- With the store on disk, you have what you [backed up](/run/upgrade-and-back-up/).
- `wardrik stop` and `wardrik pid` reach the node over Erlang distribution. See
  [Security](/run/security/#distribution).
