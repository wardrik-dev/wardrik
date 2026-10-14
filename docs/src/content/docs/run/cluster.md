---
title: Run a cluster
description: "Run several daemons as one, on one machine or several, so agents carry on when a node is lost."
sidebar:
  order: 2
---

Several daemons can run as one cluster. Any node answers for all of them, and when a node is lost
its agents carry on on another, still waiting on the calls they were waiting on.

`cluster` in `config.yaml` names the nodes:

```yaml title="~/.config/wardrik/config.yaml"
cluster:
  nodes: [a, b, c]
```

## On one machine

Short names are nodes on this machine. They share the install, the config, the cookie and the
vault's key. Each keeps its own store and log under `nodes/<name>/`.

```sh
wardrik start --node a   # a is waiting for 1 more node to reach a quorum of 2 of 3
wardrik start --node b
wardrik start --node c
wardrik status           # cluster of 3: a, b, c up
```

Under systemd, each node is an instance of `wardrik@.service`:

```sh
wardrik service install --node a
wardrik service install --node b
wardrik service install --node c
```

Try losing one:

```sh
kill -9 "$(wardrik pid --node b)"
wardrik status           # cluster of 3: a, c up; b not connected
```

## Quorum

With the store on the nodes' disks, a write lands once more than half the nodes have it. So the
cluster needs more than half its nodes up: three carry on with one lost, five with two, and two
stop when either is.

A node starting waits until enough others are up. It says so in its log every 30 seconds, and in
`wardrik status`:

```
a is waiting for 1 more node to reach a quorum of 2 of 3; connected to a
```

With the store in [Postgres or a bucket](/run/storage/), nodes don't wait for each other.

## On several machines

Name one node per machine, in full:

```yaml
cluster:
  nodes: [wardrik@box1, wardrik@box2, wardrik@box3]
```

Or find them by DNS, from each A or AAAA record of a name, with how many there should be:

```yaml
cluster:
  dns: wardrik.internal
  size: 3
```

:::caution
Nodes talk over Erlang distribution, which isn't encrypted. Anyone who reaches a node with its
cookie can run code on it. Run nodes only on a private network that encrypts, such as Tailscale or
WireGuard.
:::

Each machine has its own install, the same `cluster`, and an env file telling the node who it is:

```sh title="~/.config/wardrik/env"
WARDRIK_NODE=wardrik@box1
WARDRIK_DIST_INTERFACE={100,64,0,1}   # this machine's address on the private network
WARDRIK_DIST_EXPOSED=1
RELEASE_COOKIE=...                     # the same on every node
```

Then:

1. Give every node the same cookie, such as the first machine's `~/.local/share/wardrik/cookie`.
2. Give every node the same vault key: copy `~/.local/share/wardrik/vault_key`, or set the same
   `WARDRIK_VAULT_KEY`.
3. Keep the agent and policy files the same on every machine.
4. Open epmd's port, 4369, and the port each node chooses, between the machines.
5. Run `wardrik service install` on each machine.

## Stop a node

`wardrik stop` saves what the node holds and stops it. Its agents carry on on the others.

## Details

### Which node a command acts on

`start`, `stop`, `serve`, `remote`, `logs`, `pid`, `doctor` and `service` act on one node, and take
`--node` once there are several. Every other command asks whichever node answers, since each speaks
for the whole cluster. `reload` reads the files again on every node. `WARDRIK_NODE` sets the node
for every command.

### Shared ports

The nodes share the HTTP API's port and the terminal client's. The first node to start listens, and
another takes over the port when that one stops.

### The distribution settings

- `WARDRIK_DIST_INTERFACE` is the address distribution listens on, as an Erlang tuple, or `any`.
  Without it, distribution listens on loopback, and a node named for another host refuses to start.
- `WARDRIK_DIST_EXPOSED=1` confirms you mean it. An address beyond loopback is refused without it.
- `RELEASE_COOKIE` is the cookie. Each install makes its own at first start.

Every `wardrik` command reads `~/.config/wardrik/env`, as the service does, so commands in a shell
reach the node. `wardrik vault put` names any node it reaches that has no vault key.

### Agent files across machines

Each node reads the agent and policy files on its own machine. An agent runs while any connected
node's files declare it, and stops once none do. So a file left on one machine keeps its agent
running. The HTTP API refuses to change an agent any node's files declare.

### Odd cases

- A node not in `cluster.nodes` refuses to start.
- A node stopped without a quorum stops at once, without saving, since it couldn't write anyway.
