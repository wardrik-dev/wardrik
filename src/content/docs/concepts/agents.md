---
title: Agents
description: "An agent is a process with a model, tools, a policy and a conversation. It answers in turns, sleeps when idle, and survives a lost node."
sidebar:
  order: 1
---

An agent has a model, tools, a policy and a conversation. It answers one turn at a time. Its
state is in the store, so it carries on after a restart or a lost node.

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

- Every agent has an opaque ID, such as `agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN`. The daemon makes it.
- The daemon also keeps a name per org. The file name, `triage`, is the name.
- The `wardrik` command takes names. `org/name` reaches another org's agent.
- The HTTP API takes IDs: `GET /v1/agents/agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN`.

## Conversations

An agent can hold many conversations, such as one per Slack thread. Each has its own history and
shares the agent's definition and files. Name one with `conversation`:

```sh
wardrik ask triage "And now?" --conversation C1-1696.1234
```

```elixir
Wardrik.Agent.ask(scope, "agt_01JF8X5RQ2", "And now?", conversation: "C1-1696.1234")
```

## Turns

1. The agent takes the waiting messages and asks the model.
2. It runs the tool calls the model makes, up to 8 at once.
3. It asks the model again with the results.
4. The turn ends when the model answers without a tool call.

A call may wait for a person. That parks the turn until someone decides. See
[Approvals](/concepts/approvals/).

| Key | Default | At the limit |
| --- | --- | --- |
| `max_iterations` | 25 rounds | the turn fails |
| `timeout` | none | the turn stops, as `run.deadline_exceeded` |
| `retries` | 6 more tries | a person is asked whether to try again |

```sh
wardrik agent cancel triage        # stop the turn and drop waiting messages
wardrik agent kill triage call_1   # stop one tool call; the turn goes on
wardrik agent clear triage         # empty the history
```

## Status

`wardrik ls` shows each agent as `idle`, `running`, `parked` (waiting on a person) or `asleep`.
`wardrik ls attention` lists the parked ones.

## Sleeping

An agent idle for 15 minutes stops and costs nothing. A message, a decision or a reader wakes
it, on any node. Set `idle_timeout` in seconds, or `infinity` to never sleep.

## Changing and removing

- Edit the file, then `wardrik reload`. The conversation is kept.
- Delete the file, then `wardrik reload`, to remove the agent.
- `wardrik agent rm triage` removes an agent the HTTP API made.
- Restart the daemon after you change `config.yaml` or `policies/`.

## Durable runs

Before a round of tool calls runs, the agent writes it to the store. If the node is lost, another
node carries on from that round.

- A call that can safely run twice runs again: file reads, read-only MCP tools, `readOnly` or
  `idempotent` worker tools.
- Any other call waits for a person: "This call may have run, but its answer was lost."
- Each call has an `idempotencyKey` that stays the same. Pass it to services that take one.

```ts
wardrik.tool({
  name: "refund_order",
  input: z.object({ orderId: z.string() }),
  idempotent: true,
  run: ({ orderId }, { idempotencyKey }) =>
    stripe.refunds.create({ payment_intent: orderId }, { idempotencyKey }),
});
```

## A history that grows

At 60% of the model's context window, the agent summarises older messages. Tune it with
`compaction: {at: 0.5, keep: 0.2}`, or turn it off with `compaction: false`.

Every key is in [Agent files](/reference/agent-files/).
