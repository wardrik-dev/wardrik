---
title: Run a cluster
description: "Run several daemons as one, spread agents across them, and carry on when a node is lost."
sidebar:
  order: 2
---

Several daemons run as one cluster. Each agent runs on one node, and any node answers for all of
them. When a node is lost, its agents restart on the others, still waiting on the calls they
waited on.

```yaml title="~/.config/wardrik/config.yaml"
cluster:
  nodes: [a, b, c]
agents:
  max_per_node: 5000
```

## Spread agents

Each new agent, and each agent a lost node ran, starts on the node with the most room.

```yaml title="~/.config/wardrik/config.yaml"
agents:
  max_per_node: 5000   # agents and conversations a node runs
  max_memory: 80       # percent of the machine's memory
  max_cpu: 90          # percent of its CPU
  hibernate_after: 60  # seconds idle before an agent compacts its memory
```

- A node at `max_per_node`, or above `max_memory` or `max_cpu`, takes no new agents.
- With none set, an agent starts on the node that defined it.
- Leave room for a lost node's agents. Three nodes of 5,000 each carry 10,000 agents through the
  loss of one.
- Running agents stay where they are. `wardrik agent move AGENT NODE` moves one.
- Nodes on one machine share its memory and CPU, so only `max_per_node` spreads agents between
  them.
- `wardrik reload` applies changes.

| Three nodes on one machine, `max_per_node: 15` | a | b | c |
| --- | --- | --- | --- |
| 30 agent files, as defined | 1 | 14 | 15 |
| 47 s after `kill -9` of c | 15 | 15 | 0 |

Placement reads each node's load from heartbeats every 10 seconds, so a burst of new agents fills
one node to its limit before the next.

## On one machine

Short names are nodes on one machine. They share the config, the cookie, the vault key and the
HTTP API's port. Each keeps its own store and logs under `nodes/<name>/`.

```sh
wardrik start --node a
wardrik start --node b
wardrik start --node c
wardrik status
```

```text
Wardrik runs at http://127.0.0.1:4747.
NODE                 AGENTS
wardrik_a@localhost  12
wardrik_b@localhost  11
wardrik_c@localhost  12
0 asleep
```

- The first node to start listens on the HTTP port. Another takes it over when that one stops.
- `wardrik logs --node b` shows one node's log.
- `wardrik service install --node a` installs each node as an instance of `wardrik@.service`.

## On several machines

Name one node per machine, or find them by DNS:

```yaml title="~/.config/wardrik/config.yaml"
cluster:
  nodes: [wardrik@box1, wardrik@box2, wardrik@box3]
# or
cluster:
  dns: wardrik.internal   # a node named wardrik@ADDRESS at each A and AAAA record
  size: 3
```

Each machine's `env` file names its node and where distribution listens:

```sh title="~/.config/wardrik/env"
WARDRIK_NODE=wardrik@box1
WARDRIK_DIST_INTERFACE={100,64,0,1}   # this machine's address on the private network
WARDRIK_DIST_EXPOSED=1
RELEASE_COOKIE=...                    # the same on every node
```

- Give every node the same vault key, agent files and policies.
- Open epmd's port, 4369, and each node's distribution port between the machines.
- Erlang distribution isn't encrypted, and the cookie lets anyone who reaches a node run code on
  it. Run nodes on a private network that encrypts, such as Tailscale or WireGuard. See
  [Security](/run/security/#distribution).
- A node `cluster.nodes` doesn't name refuses to start.

## Storage and quorum

| Store | Nodes wait for | Data outlives |
| --- | --- | --- |
| The nodes' disks, the default | more than half the nodes | any node but not all |
| [Postgres](/run/storage/#in-postgres) | nothing | every node |
| [S3](/run/storage/#in-s3) | nothing | every node |

- On the nodes' disks, a write needs more than half the nodes. Three nodes carry on with one lost;
  two stop when either is. A starting node waits for enough others, up to an hour.
- In Postgres or S3, each node starts on its own and carries on while any node is up.

| Three nodes on one machine, 6 agents | On disk | S3 (MinIO, two nodes) |
| --- | --- | --- |
| First node answers | once a second node is up | 3 s, alone |
| HTTP after `kill -9` of the node holding the port | 0.9 s | — |
| Agents running again after `kill -9` | 51 s | 51 s |

A lost node's agents restart once the others' next sweep finds them, every 30 seconds.

## Model limits

The [model gateway](/run/model-gateway/) counts limits on each node. Divide each provider's quota
between the nodes.
