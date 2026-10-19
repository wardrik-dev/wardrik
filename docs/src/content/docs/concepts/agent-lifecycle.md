---
title: Lifecycle
description: "Where agents come from, how they change and go away, how they sleep when idle, and where they run in a cluster."
sidebar:
  order: 1.2
---

An agent comes from a file in `agents/` or a definition sent over the HTTP API. It sleeps when it
has nothing to do, wakes when asked, and runs on one node of a cluster at a time.

## Where agents come from

| Source | Read | Changed by |
| --- | --- | --- |
| A file in `agents/` | at start, and on `wardrik reload` | editing the file |
| `PUT /v1/agents/{key}` | at once | sending it again |
| `wardrik agent spawn NAME` | at once, from `config.yaml`'s `defaults` | `--file`, which writes it a file |

`wardrik agent spawn NAME` starts an agent nothing defines from `config.yaml`'s `defaults`, kept as
its definition; `--file` writes it a file from them first. Each definition takes the defaults' `idle_timeout` and
`retries` as it is read, and finds the policy it names each time its agent starts. See
[Agent files](/reference/agent-files/) and [Use the HTTP API](/build/http-api/).

A file's agent is changed only through its file: the HTTP API refuses, with `409`, to define it,
remove it or change its triggers.

## Changing and removing

`wardrik reload` reads every file and definition again, on the node that answers, for the whole
cluster, so every node keeps `agents/` and `policies/` alike. Each awake agent takes what its file
or definition says now; a sleeping one, or one a file adds, takes it as it wakes. The conversation
is kept, and a running turn finishes with what it started with. An agent whose file is gone stops,
and its definition goes.

To remove an agent, delete its file and run `wardrik reload`, then `wardrik agent rm KEY`. An agent
the HTTP API defined is removed with `wardrik agent rm KEY` alone.

| Command | Does |
| --- | --- |
| `wardrik agent cancel KEY` | ends the turn it's taking |
| `wardrik agent stop KEY` | stops it now, keeping its conversation; it wakes when asked |
| `wardrik agent move KEY NODE` | starts it again on another node, as it was |
| `wardrik agent rm KEY` | removes it for good |

## Sleeping

An agent with nothing to do for 15 minutes writes itself down and stops, so it costs nothing until
needed. Anything asked of it by its key wakes it, on any node, as it was:

- a message, from a channel, the HTTP API, `wardrik ask` or a trigger;
- a decision on a call it parked, or an account connected that a call waited on;
- a client attaching, or reading what it's doing.

`idle_timeout` sets how long, in seconds, or `infinity` for an agent that never sleeps:

```yaml
---
description: Answers in the team's channel.
idle_timeout: infinity
---
```

## In a cluster

An agent runs on one node at a time, and every command, on any node, reaches it. A new agent goes to
a node with room for it. When a node is lost, its agents start again on the others; see
[Durable runs](/concepts/durable-runs/) and [Run a cluster](/run/cluster/).

## Details

- **Removing a file.** Removing an agent's file, or changing its `name`, stops the agent and clears
  its triggers. The agent keeps its conversation and last definition, so a file that declares it
  again brings it back as it was. Stopped, it sleeps: asking it by its key wakes it with its last
  definition. `wardrik agent rm` removes it for good only once no file declares it.
- **Files that don't read.** `wardrik status` lists them. An agent already running carries on as
  it was until its file reads again.
- **Definitions say less than files:** no notices, no modules, and only the trees the token's scope
  covers.
- **Reading files never touches** an agent the HTTP API defined.
- **Sleep conditions.** An agent sleeps only once no turn runs and no message waits; a turn parked
  on a person doesn't keep it awake. Stopping a turn wakes nothing. `wardrik ls` and
  `GET /v1/agents` list a sleeping agent with the status it slept in, as asleep, and its log says
  `agent.stopped` with the reason `idle`.
- **Reload and sleep.** `wardrik reload` wakes no agent; a sleeping one takes its file or
  definition as it stands when it next wakes.
- **Nothing stored.** An agent with a file or definition, but nothing in the store, is listed as
  asleep, and starts from its definition when asked. So does one a new release can't read; see
  [Upgrade and back up](/run/upgrade-and-back-up/#details).
- **`idle_timeout`** goes in an agent file or a definition, or in `config.yaml`'s `defaults` for
  every agent that sets none.
- **Clusters.** Each node reads its own `agents/`, and an agent stops only once no node's files
  declare it. An agent's tools are made on the node it runs on, so every node should reach each MCP
  server. `agent move` ends a turn the agent is taking and abandons what it waits on, so it asks
  first.
