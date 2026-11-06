---
title: Run a cluster
description: "Distribute agents across multiple nodes and recover work when a node fails."
sidebar:
  order: 2
---

Run multiple Wardrik daemons as a cluster. Each agent runs on one node, but any node can handle
API requests for it. If a node fails, surviving nodes restart its agents. Pending approvals remain pending.

```yaml title="~/.config/wardrik/config.yaml"
cluster:
  nodes: [a, b, c]
agents:
  max_per_node: 5000
```

## Spread agents

New agents and agents recovering from a failed node start on the node with the most available capacity.

```yaml title="~/.config/wardrik/config.yaml"
agents:
  max_per_node: 5000   # agents and conversations a node runs
  max_memory: 80       # percent of the machine's memory
  max_cpu: 90          # percent of its CPU
  hibernate_after: 60  # seconds idle before an agent compacts its memory
```

- A node at `max_per_node`, or above `max_memory` or `max_cpu`, accepts no new agents.
- Without placement limits, an agent starts on the node that defined it.
- Reserve capacity for failover. Three nodes with a 5,000-agent limit each can support 10,000
  agents after one node fails.
- Running agents stay where they are. `wardrik agent move AGENT NODE` moves one.
- Nodes on one machine share its memory and CPU, so only `max_per_node` spreads agents between
  them.
- `wardrik reload` applies changes.

| Three nodes on one machine, `max_per_node: 15` | a | b | c |
| --- | --- | --- | --- |
| 30 agent files, as defined | 1 | 14 | 15 |
| 47 s after `kill -9` of c | 15 | 15 | 0 |

Placement uses load updates received every 10 seconds. A burst of new agents can fill one node
before agents are assigned to the next.

## On one machine

Use short node names for a cluster on one machine. They share the config, the cookie, the vault key and the
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

Set the node name and Erlang distribution address in each machine’s `env` file:

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
- Nodes not listed in `cluster.nodes` cannot start.

## Storage and quorum

| Store | Startup requirement | State survives |
| --- | --- | --- |
| Local disk (default) | a majority of nodes | loss of individual nodes; requires surviving disks |
| [Postgres](/run/storage/#in-postgres) | database available | replacement of all agent nodes |
| [S3](/run/storage/#in-s3) | bucket available | replacement of all agent nodes |

- With local storage, writes require a majority of nodes. A three-node cluster tolerates one
  failure; a two-node cluster cannot. Startup waits up to an hour for a majority.
- In Postgres or S3, each node starts on its own and carries on while any node is up.

| Three nodes on one machine, 6 agents | On disk | S3 (MinIO, two nodes) |
| --- | --- | --- |
| First node answers | once a second node is up | 3 s, alone |
| HTTP after `kill -9` of the node holding the port | 0.9 s | — |
| Agents running again after `kill -9` | 51 s | 51 s |

Surviving nodes check for agents to recover every 30 seconds.

## Model limits

The [model gateway](/run/model-gateway/) counts limits on each node. Divide each provider's quota
between the nodes.
