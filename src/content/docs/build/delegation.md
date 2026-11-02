---
title: Delegate to other agents
description: "Let an agent ask other agents for work, hear the answer back, and make workers of its own."
sidebar:
  order: 6.5
---

```yaml title="~/.config/wardrik/agents/front.md"
---
tools: [agents/*, agent_create]
---
You take requests, and hand each to the agent whose work it is. Make a worker when none does it.
```

| Tool | Does |
| --- | --- |
| `agents_list` | lists the agents it may reach, with each one's ID and status |
| `agent_read`, `agent_definition_read` | reads one's status or definition |
| `agent_ask` | sends one a message; the answer comes back later |
| `agent_create` | makes a worker by name |
| `agent_define` | defines one again |
| `agent_trigger_set`, `agent_trigger_remove` | changes one's triggers |

- Each tool names an agent by the ID `agents_list` gives.
- Reads run freely. Every change waits on a person unless the policy allows it:
  `policy: {allow: [agent_ask]}`.
- A worker is held to the policy of the agent that made it.
- `self/*` does the same for the agent itself: `self_read`, `self_trigger_set`, and so on.

## What it may reach

An agent acting through these tools is `agent:NAME`. It gets only its own bindings, never its
owner's:

```yaml title="~/.config/wardrik/config.yaml"
roles:
  delegate: {rules: [{verbs: [create, define, read, ask], kinds: [agent]}]}
bindings:
  - {org: acme, role: delegate, subjects: [agent:front]}
```

See [Orgs, roles and tokens](/run/orgs/).

## Hearing back

`agent_ask` answers at once. When the other agent's run ends, its answer arrives as a new message:

```text
From agent agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN:
In answer to your message msg_x1…:
Two deposits match no invoice: …
```

- A failed run sends `It couldn't answer:` and the error.
- A run waiting on a person sends nothing until someone decides.
- An answer carries what the other agent read. After [content from outside](/concepts/outside-content/),
  the asker's gated calls wait on a person.
