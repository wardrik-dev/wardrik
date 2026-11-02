---
title: Agents
description: "An agent is a process composed of a model, tools, a policy and conversations. It processes turns, stops when idle, and restarts on another node."
sidebar:
  order: 1
---

An agent is a process composed of a model, tools and a policy. It manages many conversations and
processes one turn at a time. Its state is persisted in the store, so it resumes after a restart
or on another node.

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
- Each agent also has a name, unique in its org. The file name, `triage`, is the name.
- The `wardrik` command takes names. Pass `org/name` for an agent in another org.
- The HTTP API takes IDs: `GET /v1/agents/agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN`.

## Conversations

An agent manages many conversations, such as one per Slack thread. Each has its own history. All
share the agent's definition and files. Pass a conversation ID to select one:

```sh
wardrik ask triage "And now?" --conversation C1-1696.1234
```

## Turns

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

After 15 idle minutes, an agent's process stops. A message, an approval or a subscriber starts it
again, on any node. Set `idle_timeout` in seconds, or `infinity` to keep it running.

## Changing and removing

- Edit the file, then `wardrik reload`. Conversations are kept.
- Delete the file, then `wardrik reload`, to remove the agent.
- `wardrik agent rm triage` removes an agent created through the HTTP API.
- Restart the daemon after you change `config.yaml` or `policies/`.

## Durable runs

The agent writes each round of tool calls to the store before running it. If the node goes down,
another node resumes from that round.

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
