---
title: Agents
description: What an agent is, how it answers a message in turns, and where it runs.
sidebar:
  order: 1
---

An agent is a process with a name, a conversation, and the model, tools and policy it was given.
It answers one message at a time, keeps what was said, and runs until it is removed. There is one
process for each agent across a cluster, and its state is kept in the store, so when the node it
runs on is lost it carries on on another.

## Keys and orgs

Every agent belongs to an org, and may work for one of its users. Its key says which:

| Key | The agent |
| --- | --- |
| `acme/triage` | acme's own `triage` |
| `acme/@jon/triage` | jon's `triage`, in acme |

An org is the boundary between agents. A [token](/operate/security/#tokens) reaches the agents of
an org, `acme/`, or of one of its users, `acme/@jon/`. A
[shared tree](/concepts/files-and-memory/#sharing-trees) belongs to an org or a user, and an
[MCP server](/guides/mcp/#which-orgs-a-server-serves) and a
[notice target](/guides/notices/#which-orgs-a-target-tells) serve one org unless `config.yaml` says
others.

The deployment has an org of its own, `default` unless `config.yaml` names another:

```yaml title="~/.config/wardrik/config.yaml"
org: acme
```

An agent file that names no `org` is in it, and the CLI finds an agent in it by its name alone, or
a user's by `@user/name`:

```sh
wardrik ask triage "What changed today?"      # acme/triage
wardrik show @jon/triage                      # acme/@jon/triage
wardrik show globex/triage                    # another org's
```

Over the HTTP API, the key is the path, always in full: `/v1/agents/acme/@jon/triage`.

An org, a user and a name each hold no `/` or whitespace, and do not begin with `@` or `_`. They
are in every event's `source`, in store keys and in logs, so a user's should be an id, not an email
address.

## Where agents come from

An agent is declared by a file in `agents/` under the config directory, or defined over the HTTP
API.

- **A file** is read when the daemon starts, and again with `wardrik reload`, which gives each
  agent awake what its file says now; one [asleep](#sleeping) takes it as it wakes. `wardrik agent spawn NAME` writes one from `config.yaml`'s
  `defaults` and starts its agent. See [Agent files](/reference/agent-files/).
- **A definition** is sent with `PUT /v1/agents/{key}`, by a token that can
  `define`, and takes effect at once. It says less than a file can: no notices, no modules, and only
  the trees its token's scope covers. See [Use the HTTP API](/guides/http-api/).

An agent belongs to whichever made it. A file's agent is changed through its file: the HTTP API
refuses, with `409`, to define it, remove it or change its triggers. Removing the file and running
`wardrik reload` stops the agent and clears its triggers, and so does changing the file's `name`.
The agent keeps its conversation and the definition it last had, so a file that declares it again
brings it back as it was. Stopped, it [sleeps](#sleeping): anything asked of it by its key wakes it,
with the definition it last had where no file declares it any more. To be rid of it, `wardrik agent
rm KEY` removes it for good once no file declares it. An agent the HTTP API defined is never touched by
reading the files, and `wardrik agent rm KEY` removes it too.

In a [cluster](/operate/cluster/) each node reads its own `agents/`, and an agent stops only once no
node's files declare it.

`wardrik agent cancel` ends the turn an agent is taking, `agent stop` stops it now, keeping its
conversation, and it wakes when something asks it again; and `agent move` starts it again on another node, as it was. See
[the CLI](/reference/cli/).

A file that does not read is listed by `wardrik status`, and the agent it declared, if one runs,
carries on as it was until the file reads again.

## Turns

An agent answers in turns. A turn takes the messages waiting for the agent, asks the model, runs the
tool calls the model makes, and asks the model again with their results, until the model answers
without calling anything.

- **Messages wait their turn.** The messages waiting when a turn begins are answered together. One
  that arrives during a turn asks it to stop at its next step: the model's reply and its tool calls
  finish, and the next turn answers the new message with everything the last one left.
- **A turn is bounded.** `max_iterations` is how many rounds of tool calls it may make, 30 unless an
  agent file says otherwise. At the limit, the model is asked once more, without tools, to answer
  with what it has.
- **A turn may have a deadline.** `timeout` is how many seconds a turn may take, and there is none
  unless an agent file says. At the deadline the turn stops at its next step and ends, as
  `run.deadline_exceeded`.
- **A failed model call is asked again.** One that fails for a passing reason, such as a timeout, a
  dropped connection or a provider's 5xx, before its answer begins or part way through it, is asked
  again after each wait `retries` lists, in seconds, before the turn fails: `[1, 5]` unless an agent
  file or `config.yaml`'s `defaults` say otherwise. What a failed try had streamed is dropped, and
  the next try answers as a message of its own. `retries: [2, 10, 30]` waits longer for a slow
  provider, and `retries: []` never asks again.
- **Tool calls run together.** Up to 8 of a round's calls run at once, and each may take up to 60
  seconds.

A tool call may wait on a person, which parks the turn until it is decided. See
[Policy and approvals](/concepts/policy/).

### Stopping a turn

`wardrik agent cancel KEY`, `POST /v1/agents/{key}/cancel`, or `/stop` in the
[terminal client](/guides/tui/), stops the running turn, drops the messages waiting behind it, and
abandons a parked one. A turn that stops within two seconds keeps what it said; one that does not is
ended, and adds nothing. Stopping a turn does not stop the agent, which answers the next message as
usual, and a stopped turn stays stopped on whichever node holds the agent next.

```sh
wardrik agent cancel triage       # acme/triage
wardrik agent cancel acme/@jon/   # every agent of jon's
wardrik agent cancel --all        # every agent there is
```

`wardrik stop` is the daemon's, and stops every agent with it.

## Status

An agent is one of:

| Status | |
| --- | --- |
| `idle` | waiting for a message |
| `running` | answering one, which may begin by summarising its history |
| `parked` | waiting on a person |

`wardrik ls` shows each agent's status, the node it runs on, when it next runs and what it has
spent. An agent whose last turn failed shows as `idle, last failed`, and `wardrik show` says why.

```sh
wardrik ls                    # every agent
wardrik ls org:acme triage    # acme's agents with triage in their key
wardrik ls @jon               # jon's agents
wardrik ls attention          # the agents waiting on a person
```

A query is words that must all match: text in the key, `name:`, `org:`, `user:`, `node:`, and
`status:idle`, `status:running` or `status:parked`.

## Sleeping

An agent with nothing to do for 15 minutes writes itself down and stops, so it costs nothing until it
is needed. It sleeps only once no turn is running and no message waits; a turn parked on a person
does not keep it awake. Anything asked of it by its key wakes it, on whichever node, as it was:

- a message, from a channel, the HTTP API, `wardrik ask` or a trigger;
- a decision on a call it parked, or an account connected that a call waited on;
- a client attaching, or reading what it is doing.

Stopping a turn wakes nothing, since a sleeping agent has none. `wardrik ls` and `GET /v1/agents`
list a sleeping agent with the status it slept in and as asleep, and its log says
`agent.stopped`, with the reason `idle`, as it goes.

A sleeping agent wakes with its definition as it reads then, so `wardrik reload` changes the agents
awake and wakes none: one asleep takes its file or definition as it stands when it next wakes.

`idle_timeout` sets how long, in seconds, or `infinity` for an agent that never sleeps: in an agent
file or a definition for one agent, and in `config.yaml`'s `defaults` for every agent that sets
none.

```yaml
---
description: Answers in the team's channel.
idle_timeout: infinity
---
```

## The conversation

An agent keeps everything said to it and by it, and `wardrik history` prints it. Its system prompt,
the body of its file, is not part of the conversation: it is put in front of every turn, so changing
it changes the agent from its next turn.

An agent that runs for weeks summarises the older part of its history before it outgrows what the
model can read. See [Durable runs](/concepts/durable-runs/#a-history-that-grows).

`wardrik reload` keeps the conversation. What a file says now applies from the agent's next turn, or
as a sleeping agent wakes, and a turn already running finishes with what it started with.

`wardrik clear AGENT` empties the conversation of an agent that is not running a turn or waiting on
a person, keeping its files, triggers and config. It is how an agent that read content from outside
is rid of it: until then, its gated tools ask a person on every turn. See
[Policy and approvals](/concepts/policy/#content-from-outside).

## In a cluster

An agent runs on one node of a cluster at a time, and every command, on any node, reaches it.
A new agent goes to a node with room for it.

When a node is lost, its agents start again on the others, from what each last wrote to the store:

- an agent waiting on a person is waiting on the same calls;
- a turn that had begun running tool calls carries on from them, without asking the model again;
- a turn that had not, starts again.

The tools an agent has are made on the node it runs on, so an MCP server should be reachable from
every node. See [Durable runs](/concepts/durable-runs/) and [Run a cluster](/operate/cluster/).

## Delegation

`deep_research` hands a question to subagents: several researchers at once, each with a turn of its
own, and one more to bring what they found together. A subagent has no conversation of its own and
cannot wait on a person: a call that would ask one is refused. It has its caller's tools, as they
are gated, and a subagent that reads content from outside marks the call that ran it, as reading it
directly would. What a subagent does is in its caller's event stream, as `subagent.started`,
`subagent.completed` and `subagent.failed`, with its own events beneath them.

An application running Wardrik as a library delegates with `Wardrik.Subagent.run/3`, from a tool or
a workflow.
