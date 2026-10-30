---
title: Delegate to other agents
description: "Let an agent ask the other agents of its org for work, hear the answer back, and define workers of its own."
sidebar:
  order: 6.5
---

An agent with `agents/*` in its tools works with the other agents of its org. It can see what each
is doing, ask one for something and hear back, and define a worker.

```yaml title="~/.config/wardrik/agents/front.md"
---
model: anthropic:claude-sonnet-5
tools: [agents/*]
---
You take requests, and hand each to the agent whose work it is. Define a worker when none does it.
```

| Tool | Does |
| --- | --- |
| `agents_list` | lists the agents of the org, and what each is doing |
| `agent_read` | reads one's snapshot: its status, and what it waits on |
| `agent_definition_read` | reads one's definition |
| `agent_ask` | sends one a message; the answer comes back later |
| `agent_define` | defines one, or defines it again |
| `agent_trigger_set`, `agent_trigger_remove` | changes one's triggers |

Each tool takes the `agent` it acts on, by name within the org: `reconciler`, or `@jon/reconciler`
for one that works for a user.

## Ask another agent

`agent_ask` answers at once, and the asking agent carries on. When the other agent's run ends, its
answer arrives as a message, which starts a turn of its own:

```text
From agent acme/reconciler:
In answer to your message msg_x1…:
Two deposits match no invoice: …
```

| The other agent's run | The asking agent hears |
| --- | --- |
| completes | its answer |
| fails | `It couldn't answer:` and the error |
| is cancelled | `It stopped before it answered.` |
| waits on a person | nothing yet; the answer comes once someone decides |

## Define a worker

`agent_define` takes a whole definition, as [`PUT /v1/agents/{agent}`](/build/http-api/) does:

```json
{
  "agent": "reconciler",
  "definition": {
    "model": "anthropic:claude-haiku-4-5",
    "description": "Reconciles deposits.",
    "instructions": "Match each deposit to an invoice, and say which match none.",
    "tools": ["files"]
  }
}
```

A worker is held to the policy of the agent that defined it, so it can never do more than its
definer.

## Approvals

Asking, defining and changing triggers each wait on a person, unless the policy allows the tool by
name. Reads run freely:

```yaml
policy:
  allow: [agent_ask]
```

See [Approvals](/concepts/approvals/).

## Details

- `self/*` offers the same operations on the agent itself, with no `agent` to name: `self_read`,
  `self_definition_read`, `self_trigger_set` and `self_trigger_remove`.
- An agent reaches its own org only. To it, an agent in another org doesn't exist.
- A run that ends while the daemon is down is answered once it's back. A repeated answer is dropped.
- An answer carries what the other agent read. After it read content from outside, so has the agent
  that hears it, and its gated calls wait on a person from then on. See
  [Content from outside](/concepts/outside-content/).
- A worker runs as an agent defined over the [HTTP API](/build/http-api/). `wardrik ls`
  lists it.
- An agent its file declares refuses to be defined this way.
- A person approving sees what the agent would send or define. Decide with
  `wardrik approval approve AGENT CALL`, or in the channel that asked.
- After the agent reads content from outside, an `allow` rule stops counting, as for every gated
  tool.
