---
title: Durable runs
description: "A turn survives a lost node, a call that may have run waits for a person before it runs again, and a long history is summarised before it outgrows the model."
sidebar:
  order: 1.3
---

An agent writes its state to the store as it changes: its conversation, the messages waiting, and
what it's doing. Whichever node holds the agent next, after a restart or a lost node, carries on
from there.

## A turn lost part way

Before a round of tool calls runs, the agent writes the round to the store. A turn whose node is
lost comes back on another node at that round, with the same calls, rather than asking the model
again.

| When the node was lost | What happens |
| --- | --- |
| The agent was waiting on a person | It waits on the same calls |
| A round of tool calls was running | The round's calls run again, or wait for a person |
| The model was answering, before any tool call | The turn starts again |

<a id="the-ledger"></a>

## Calls that may have run

Any call of a lost round may have done its work before the node went. So each one is decided
again:

- **An idempotent call runs again.** Running it twice has no second effect.
- **Any other call waits on a person:**

  > This call may have run, but its answer was lost. Approve it to run it again, or deny it.

| Idempotent | Not idempotent |
| --- | --- |
| `read_file`, `list_files`, `search_files`, `delete_file` | `write_file`, `edit_file` |
| an MCP server's read-only tools | an MCP server's other tools |
| a tool worker's `readOnly` or `idempotent` tools | a tool worker's other tools |

Denying the call tells the model it may have run, so it can find out.

### Idempotency keys

Each call has an id, the same every time the call runs. A [tool worker](/build/write-tools/#running-a-call-twice)
receives it as `idempotencyKey`. A tool with an outside effect passes the key on, so the system it
calls doesn't repeat the effect either. A payment provider, for one, takes it as its own
idempotency key:

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

Before an agent's history outgrows what its model can read, the agent summarises the older part
with its own model, and keeps the most recent part word for word. By default it summarises at 60%
of the model's context window and keeps the last 25%:

```yaml
compaction: {at: 0.5, keep: 0.2}    # summarise sooner, keep less
compaction: {window: 200000}        # the window, where the model catalog has none
compaction: false                   # never summarise
```

## Details

- **What's written when.** An agent writes each round of tool calls, each message it takes and
  each decision as they happen. A node killed outright comes back from what it last wrote. Text the
  model had streamed but not finished isn't kept.
- **Stopping the daemon.** A turn running when the daemon stops comes back as a lost one does.
- **Tool workers.** A worker that goes away mid-call, or answers late, leaves the call in doubt the
  same way. It runs again on another worker if every worker offering the tool marks it read-only or
  idempotent.
- **MCP servers** aren't sent the idempotency key.
- **Failed turns.** Retries are covered in [Turns](/concepts/turns/#limits-on-a-turn). A failed
  turn isn't tried again. The agent goes back to `idle`, its log says why with `run.failed`, and a
  `notify` route with `failed` says so. The next message starts a turn as usual.
- **Compaction.** Where the model catalog doesn't give a context window, 128,000 tokens is used. It
  happens as a turn begins, and is reported as `wardrik.conversation.compacted` with message and
  token counts before and after. The summary is a model call like any other: the policy decides
  it, the budget counts it, and stopping the turn stops it.
