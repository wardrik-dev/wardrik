---
title: Run a cluster
description: Run several daemons as one, on one machine or several, so agents carry on when a node is lost.
sidebar:
  order: 2
---

Several daemons can run as one cluster. Their agents, schedules and store span every node, any
node answers for all of them, and the agents of a node that is lost carry on on another, waiting
on the same calls they were waiting on.

`cluster` in `config.yaml` names the nodes:

```yaml title="~/.config/wardrik/config.yaml"
cluster:
  nodes: [a, b, c]
```

## On one machine

Short names are nodes on this machine. They share the install, its config directory, its cookie and
the vault's key, and each keeps a store and a log of its own, under `nodes/<name>/`:

```sh
wardrik start --node a   # a is waiting for 1 more node to reach a quorum of 2 of 3
wardrik start --node b
wardrik start --node c
wardrik status           # cluster of 3: a, b, c up
```

`start`, `stop`, `serve`, `remote`, `logs`, `pid`, `doctor` and `service` act on one node, and take
`--node` once there are several. Every other command asks whichever node answers, since each speaks
for the whole cluster, and `reload` reads the files again on every node. `WARDRIK_NODE` sets the node
for every command.

Under systemd, each node is an instance of `wardrik@.service`:

```sh
wardrik service install --node a
wardrik service install --node b
wardrik service install --node c
```

The nodes share the HTTP API's port and the terminal client's: the first node to start listens, and
another takes the port over when that one stops.

Try losing one:

```sh
kill -9 "$(wardrik pid --node b)"
wardrik status           # cluster of 3: a, c up; b not connected
```

## Quorum

With the store on the nodes' disks, a write is made once more than half of the nodes have it, so the
cluster needs more than half of them up: three carry on with one lost, five with two, and two stop
when either is. A node starting waits until enough of the others are up, and says so in its log
every 30 seconds, and in `wardrik status`:

```
a is waiting for 1 more node to reach a quorum of 2 of 3; connected to a
```

With the store in [Postgres or a bucket](/operate/storage/), nodes start and carry on without
waiting for each other.

A node not in `cluster.nodes` refuses to start.

## On several machines

Nodes on several machines are named in full, one to each machine:

```yaml
cluster:
  nodes: [wardrik@box1, wardrik@box2, wardrik@box3]
```

or found by DNS, from each A or AAAA record a name has, with how many there are to be:

```yaml
cluster:
  dns: wardrik.internal
  size: 3
```

Nodes reach each other with Erlang distribution, which is not encrypted, and anyone who reaches a
node with its cookie can run code on it. Run them on a private network that encrypts, such as
Tailscale or WireGuard, and nowhere else.

Each machine has its own install and the same `cluster`. Each node needs to know its name, where to
listen, and the cluster's cookie:

```sh title="~/.config/wardrik/env"
WARDRIK_NODE=wardrik@box1
WARDRIK_DIST_INTERFACE={100,64,0,1}   # this machine's address on the private network
WARDRIK_DIST_EXPOSED=1
RELEASE_COOKIE=...                     # the same on every node
```

- `WARDRIK_DIST_INTERFACE` is the address distribution listens on, written as an Erlang tuple, or
  `any`. Without it, distribution listens on loopback, and a node named for another host refuses to
  start.
- `WARDRIK_DIST_EXPOSED=1` says you mean it: an address beyond loopback is refused without it.
- `RELEASE_COOKIE` is the cookie. Each install makes its own at first start, so give every node the
  same one, such as the first machine's `~/.local/share/wardrik/cookie`.

The vault's key has to be the same on every node too. Copy the first machine's
`~/.local/share/wardrik/vault_key` to each, or give every node the same `WARDRIK_VAULT_KEY`.
`wardrik vault put` names any node it reaches that has no key.

Each node reads the agent and policy files on its own machine. Keep them the same everywhere: an
agent runs while any connected node's files declare it, and stops once none do, so a file left on
one machine keeps its agent running. The HTTP API refuses to change an agent any node's files
declare.

Every `wardrik` command reads `~/.config/wardrik/env`, as the service does, so commands run in a
shell reach the node. Then install the service on each machine with `wardrik service install`.

Distribution uses Erlang's port mapper, epmd, on port 4369, and a port it chooses for each node.
Let the nodes reach each other on both over the private network.

## Stopping a node

`wardrik stop` writes down what the node holds and stops it, and its agents carry on on the others.
A node stopped without a quorum stops at once, without writing, since it could not write anyway.
