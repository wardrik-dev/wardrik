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
| A file in `agents/` | as the daemon starts, and on `wardrik reload` | editing the file, then `wardrik reload` |
| `PUT /v1/agents/{agent}` | at once | sending it again |

Keys a definition leaves out come from `config.yaml`'s `defaults`, such as `model` and
`idle_timeout`. See [Agent files](/reference/agent-files/) and
[Use the HTTP API](/build/http-api/).

A file's agent is changed through its file. The next `wardrik reload` puts back what the file
says, and the HTTP API refuses to remove it.

## Changing and removing

`wardrik reload` reads every agent file again, for the whole cluster. Each agent takes what its
file or definition says now. The conversation is kept.

```sh
wardrik reload                   # every agent
wardrik reload 'acme/agent/*'    # brings only these agents to their definitions
```

Policy files and `config.yaml` are read as the daemon starts. Restart it after you change them.

To remove an agent, delete its file and run `wardrik reload`. An agent the HTTP API defined is
removed with `wardrik agent rm AGENT`.

| Command | Does |
| --- | --- |
| `wardrik agent cancel AGENT` | ends the turn it's taking |
| `wardrik agent stop AGENT` | stops it now, keeping its conversation; it wakes when asked |
| `wardrik agent start AGENT` | starts an agent that sleeps |
| `wardrik agent move AGENT NODE` | starts it again on another node, as it was |
| `wardrik agent rm AGENT` | removes it for good, with everything it had |

## Sleeping

An agent with nothing to do for 15 minutes writes itself down and stops, so it costs nothing until
needed. Anything asked of it by its ID wakes it, on any node, as it was:

- a message, from a channel, the HTTP API, `wardrik ask` or a trigger;
- a decision on a call it parked, or an account connected that a call waited on;
- a client reading what it's doing.

`idle_timeout` sets how long, in seconds, or `infinity` for an agent that never sleeps:

```yaml
---
description: Answers in the team's channel.
idle_timeout: infinity
---
```

## In a cluster

An agent runs on one node at a time, and every command, on any node, reaches it. When a node is
lost, its agents start again on the others. See [Durable runs](/concepts/durable-runs/) and
[Run a cluster](/run/cluster/).

`wardrik status` lists the nodes and how many agents each holds.

## Details

- **Removing a file.** Removing an agent's file, or changing its `name`, removes the agent on the
  next `wardrik reload`, with its conversation and triggers.
- **Definitions refused.** `wardrik reload` and `wardrik doctor` say which files don't read. An
  agent whose file gives a definition Wardrik refuses, such as one naming a policy `policies/`
  doesn't hold, keeps its last definition until the file is fixed.
- **Sleep conditions.** An agent sleeps only once no turn runs and no message waits. A turn parked
  on a person doesn't keep it awake. `wardrik ls` and `GET /v1/agents` list a sleeping agent as
  `asleep`, and its log says `agent.stopped`.
- **Reload and sleep.** `wardrik reload` wakes no agent. A sleeping one takes its definition as it
  stands when it next wakes.
- **`idle_timeout`** goes in an agent file or a definition, or in `config.yaml`'s `defaults` for
  every agent that sets none.
- **Moving.** `agent move` ends the turn the agent is taking and abandons what it waits on.
