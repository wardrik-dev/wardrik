---
title: Delegate to other agents
description: Let an agent ask the other agents of its org for work and hear the answer back, and define the workers it needs, under its own policy and budget.
sidebar:
  order: 1.5
---

An agent with `agents/*` in its tools works with the other agents of its org: it can see what each
is doing, send one a message and hear its answer back, and define a worker of its own.

```yaml title="~/.config/wardrik/agents/front.md"
---
model: anthropic:claude-sonnet-5
tools: [agents/*]
---
You take requests, and hand each to the agent whose work it is. Define a worker when none does it.
```

Each tool takes the `agent` it acts on, by its name within the org, as `reconciler`, or
`@jon/reconciler` for one that works for a user:

| Tool | Does |
| --- | --- |
| `agents_list` | lists the agents of the org, and what each is doing |
| `agent_read` | reads one's snapshot: its status, what it waits on, its conversation |
| `agent_definition_read` | reads one's definition |
| `agent_ask` | sends one a message, whose answer comes back later |
| `agent_define` | defines one from a whole definition, or defines it again |
| `agent_trigger_set`, `agent_trigger_remove` | changes one's triggers |

`self/*` offers the same operations on the agent itself, as `self_read` or `self_trigger_set`, with
no `agent` to name. An agent reaches its own org and no other: an agent named in another org is one
that does not exist, to it.

## Asking another agent

`agent_ask` sends the message and answers at once with its id; the asking agent goes on with its
turn. Once the turn that takes the message ends, the answer comes back to the asking agent as a
message from the agent it asked, which starts a turn of its own:

```text
From agent acme/reconciler:
In answer to your message 0192f3a1-…:

Two deposits match no invoice: …
```

What comes back depends on how that turn ends:

| The delegate's turn | The asking agent hears |
| --- | --- |
| finishes | its answer, the text of its last message |
| fails | that it could not answer |
| is stopped, or the message is dropped from its queue | that it stopped before answering |
| waits on a person | nothing yet: the answer comes once someone decides |
| is lost with its node, or the agent is stopped | the answer, once the agent takes the turn up again |

An asking agent that is asleep wakes for the answer, and one that is busy takes it in its next turn.
An agent that is forgotten hears nothing, and one forgotten before it answers tells nobody.

The answer holds what the delegate read. After it has read content from outside, such as a web page,
so has the agent that hears its answer, and its gated calls wait on a person from then on, as they
would had it read the page itself. Reading a delegate with `agent_read` does the same. See
[Content from outside](/concepts/policy/#content-from-outside).

## Defining a worker

`agent_define` takes a whole definition, as `PUT /v1/agents/{key}` does, and starts the agent where
none runs:

```json
{
  "agent": "reconciler",
  "definition": {
    "description": "Reconciles deposits.",
    "instructions": "Match each deposit to an invoice, and say which match none.",
    "tools": ["files"]
  }
}
```

A worker is held to the policies and budget of the agent that defined it, ahead of its own
definition's, so it can never do what its definer could not. It is kept and runs as an agent defined
over the [HTTP API](/guides/http-api/) does: `wardrik ls` lists it, and `wardrik reload` rebuilds it
under the same limits. An agent its file declares refuses to be defined this way, as it refuses the
HTTP API.

## Approvals

Asking, defining and changing triggers are changes, so each waits on a person, who sees what the
agent would send or define, unless the agent's policy allows it by the tool's name:

```yaml
policy:
  allow: [agent_ask]
```

Reads run without asking. Decide a waiting call with `wardrik approve`, or in the channel that asked.
After the agent has read content from outside, an `allow` rule stops counting, as for every gated
tool. See [Policy and approvals](/concepts/policy/).
