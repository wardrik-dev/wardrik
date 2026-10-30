---
title: Agents
description: "An agent is a named process with a conversation, a model, tools and a policy. It answers in turns, and carries on when its node is lost."
sidebar:
  order: 1
  label: Overview
---

An agent is a process with an ID, a conversation, and the model, tools and policy it was given. It
answers one message at a time and keeps what was said. Its state lives in the store, so when its
node is lost it carries on on another.

```markdown title="~/.config/wardrik/agents/triage.md"
---
description: Keeps notes on the incident queue.
tools: [files, linear/*]
policy: careful
---
You help the on-call engineer.
```

```sh
wardrik ask triage "What changed today?"
```

<a id="keys-and-orgs"></a>

## IDs and orgs

Every agent belongs to an org, and may work for one of its users. Its ID says which:

| ID | The agent |
| --- | --- |
| `acme/triage` | acme's own `triage` |
| `acme/@jon/triage` | jon's `triage`, in acme |
| `acme/triage/C1-1696.1234` | one conversation of `acme/triage`, such as a Slack thread |

An org is the boundary between agents. [Tokens](/run/tokens/),
[shared trees](/concepts/files-and-memory/#sharing-trees),
[MCP servers](/build/mcp/#which-orgs-a-server-serves) and
[notice targets](/build/notices/#which-orgs-a-target-tells) each reach one org unless configured
otherwise.

The deployment's own org is `default`, unless `config.yaml` sets `org`. Other orgs are declared
under `orgs`; see [Orgs](/run/orgs/#declare-an-org).

The CLI finds an agent of the deployment's org by its name alone, and a user's by `@user/name`:

```sh
wardrik ask triage "What changed today?"      # acme/triage
wardrik agent show @jon/triage                # acme/@jon/triage
wardrik agent show globex/triage              # another org's
```

Over the HTTP API the ID is the path, always in full: `/v1/agents/acme/@jon/triage`. A
conversation's last part follows `conversations/`, as
`/v1/agents/acme/triage/conversations/C1-1696.1234`.

## Status

| Status | The agent is |
| --- | --- |
| `idle` | waiting for a message |
| `running` | answering one |
| `parked` | waiting on a person |
| `asleep` | stopped until something asks it; see [Sleeping](/concepts/agent-lifecycle/#sleeping) |

`wardrik ls` shows each agent's status, its queued messages, when it next runs and what it has
spent today:

```sh
wardrik ls                    # every agent
wardrik ls org:acme triage    # acme's agents with triage in their ID
wardrik ls attention          # the agents waiting on a person
```

## In this section

- [Turns](/concepts/turns/): how an agent answers, its limits, stopping a turn, its conversation,
  and subagents.
- [Lifecycle](/concepts/agent-lifecycle/): where agents come from, changing and removing them,
  sleeping, and clusters.
- [Durable runs](/concepts/durable-runs/): how a turn survives a lost node.

## Details

- **Names.** An org, a user and a name hold no `/`, `:`, `*`, `?` or whitespace, and don't begin
  with `@` or `_`. They appear in event sources, store keys and logs, so make a user's an id, not
  an email address.
- **Conversations** run on their agent's definition, with a history of their own. `wardrik ls`
  counts each agent's conversations; `wardrik ls --all` lists them too.
- **History.** A `running` agent may begin a turn by summarising its history; see
  [A history that grows](/concepts/durable-runs/#a-history-that-grows).
- **Queries.** `wardrik ls` takes words that must all match: text in the ID, `name:`, `org:`,
  `user:`, `node:`, `status:` with any status above, and `attention`. `@jon` lists jon's agents.
- **Resources.** Tokens and patterns name an agent as a resource: `acme/agent/triage` for
  `acme/triage`, and `acme/@jon/agent/triage` for `acme/@jon/triage`. `acme/agent/*` covers
  acme's own agents.
