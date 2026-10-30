---
title: Run a cluster
description: "The daemon runs as one node. What carries on when its machine is lost, and what config.yaml's cluster does today."
sidebar:
  order: 2
---

The daemon runs as one node, `wardrik@localhost`. `wardrik status` lists it:

```sh
wardrik status
```

```
Wardrik runs at http://127.0.0.1:4747.
NODE               AGENTS
wardrik@localhost  3
2 asleep
```

## What carries on when the machine is lost

Keep the store in [Postgres](/run/storage/#in-postgres), and the vault's key off the machine.
A new machine pointed at the same database and key carries on with every agent. See
[Move to a new machine](/run/storage/#move-to-a-new-machine).

With the store on disk, what you have is what you backed up. See
[Upgrade and back up](/run/upgrade-and-back-up/).

## `cluster` in `config.yaml`

The daemon doesn't join nodes into a cluster. It passes over a `cluster` key in `config.yaml`, and
says so:

```
warn  config         cluster isn't supported here yet, so it's passed over
```

## Details

### Commands that name nodes

`wardrik status` lists the nodes, and `wardrik agent move AGENT NODE` starts an agent again on
another. With one node, `agent move` has nowhere to send it.

### Distribution

The node still speaks Erlang distribution: `wardrik stop` and `wardrik pid` reach it that way.
See [Security](/run/security/#distribution).
