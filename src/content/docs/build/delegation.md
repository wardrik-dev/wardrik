---
title: Delegate to other agents
description: "Let an agent message other agents, receive their replies, and create workers."
sidebar:
  order: 6.5
---

```yaml title="~/.config/wardrik/agents/dispatch.md"
---
tools: [agents/*, agent_create]
---
Send each request to the agent that handles it. Create a worker when none does.
```

| Tool | Does |
| --- | --- |
| `agents_list` | lists the agents it can access, with ID and status |
| `agent_read`, `agent_definition_read` | returns an agent's status or definition |
| `agent_ask` | sends an agent a message; the reply arrives later |
| `agent_create` | creates a worker by name |
| `agent_define` | replaces an agent's definition |
| `agent_trigger_set`, `agent_trigger_remove` | sets or removes an agent's triggers |

- Each tool takes an agent ID from `agents_list`.
- Reads run without approval. Changes need approval unless the policy allows them:
  `policy: {allow: [agent_ask]}`.
- A worker inherits the policy of the agent that created it.
- `self/*` has the same tools for the agent itself: `self_read`, `self_trigger_set`, and so on.

## Access

These tools run as the subject `agent:NAME`, authorized by that subject's bindings, not the
owner's:

```yaml title="~/.config/wardrik/config.yaml"
roles:
  delegate: {rules: [{verbs: [create, define, read, ask], kinds: [agent]}]}
bindings:
  - {org: acme, role: delegate, subjects: [agent:dispatch]}
```

See [Orgs, roles and tokens](/run/orgs/).

## Replies

`agent_ask` returns immediately. When the other agent's turn ends, its reply arrives as a new
message:

```text
From agent agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN:
In answer to your message msg_x1…:
Two deposits match no invoice: …
```

- A failed turn sends `It couldn't answer:` and the error.
- A turn paused for approval sends nothing until it's approved or denied.
- A reply copies the other agent's labels. After [content from outside](/concepts/outside-content/),
  the sender's gated calls need approval.
