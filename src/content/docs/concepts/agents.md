---
title: Agents
description: "Define agents, manage conversations, and recover work after a restart."
sidebar:
  order: 1
---

Define an agent’s instructions, model, tools, and permissions in a Markdown file. Wardrik saves
its conversations and execution state so it can resume after a restart or recover on another cluster node.

```markdown title="~/.config/wardrik/agents/triage.md"
---
description: Keeps notes on the incident queue.
tools: [files, linear/*]
policy: careful
---
You help the on-call engineer.
```

```sh
wardrik reload
wardrik ask triage "What changed today?"
```

## IDs and names

- The daemon generates each agent's ID, such as `agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN`.
- Agent names are unique within an organization (org). The file `triage.md` defines the agent `triage`.
- The `wardrik` command takes names. Pass `org/name` for an agent in another org.
- The HTTP API takes IDs: `GET /v1/agents/agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN`.

## Conversations

An agent can have multiple conversations, each with its own message history. For example, each Slack
thread is a conversation. Conversations share the agent’s configuration and files. Select one with `--conversation`:

```sh
wardrik ask triage "And now?" --conversation C1-1696.1234
```

## Turns

A turn processes queued messages, runs tool calls, and produces a reply:

1. The agent receives the queued messages and calls the model.
2. It runs the model's tool calls, up to 8 in parallel.
3. It calls the model again with the results.
4. The turn ends when the model replies with no tool calls.

A tool call that needs approval pauses the turn until a person approves or denies it. See
[Approvals](/concepts/approvals/). `max_iterations`, `timeout` and `retries` limit a turn. See
[Agent files](/reference/agent-files/#keys).

```sh
wardrik agent cancel triage        # stop the turn and drop queued messages
wardrik agent kill triage call_1   # stop one tool call; the turn goes on
wardrik agent clear triage         # empty the history
```

## Status

`wardrik ls` shows each agent's status: `idle`, `running`, `parked` (waiting for approval) or
`asleep`. `wardrik ls attention` lists parked agents.

## Sleeping

After 15 idle minutes, Wardrik stops the agent’s process and keeps its saved state. A message,
approval, or event subscriber restarts it on an available node. Set `idle_timeout` in seconds, or `infinity` to keep it running.

## Changing and removing

- Edit the file, then `wardrik reload`. Conversations are kept.
- Delete the file, then `wardrik reload`, to remove the agent.
- `wardrik agent rm triage` removes an agent created through the HTTP API.
- Restart the daemon after you change `config.yaml` or `policies/`.

## Durable runs

Wardrik saves each round of tool calls before executing it. After a restart, or a node failure in
a cluster, the agent resumes from the saved round. Completed calls replay their saved results.

- Calls that are safe to repeat run again: file reads, read-only MCP tools, and `readOnly` or
  `idempotent` worker tools.
- Any other call needs approval: "This call may have run, but its answer was lost."
- Each call has a stable `idempotencyKey`. Pass it to services that accept one.

```ts
wardrik.tool({
  name: "refund_order",
  input: z.object({ orderId: z.string() }),
  idempotent: true,
  run: ({ orderId }, { idempotencyKey }) =>
    stripe.refunds.create({ payment_intent: orderId }, { idempotencyKey }),
});
```

## Compaction

When the history reaches 60% of the context window, older messages are summarised. See
[`compaction`](/reference/agent-files/#compaction).
