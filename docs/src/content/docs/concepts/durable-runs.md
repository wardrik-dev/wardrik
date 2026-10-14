---
title: Durable runs
description: "A turn survives a lost node, the ledger keeps a tool call from running twice, and a long history is summarised before it outgrows the model."
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
| A round of tool calls was running | The round runs again, through the ledger |
| The model was answering, before any tool call | The turn starts again |

## The ledger

Every call is claimed in the ledger before it runs and settled after. When a round runs again, the
ledger decides each call:

- **A call that finished** is answered with what it returned, without running again. Its
  `tool_call.completed` event says `"replayed": true`.
- **A call that began and never finished** may have done its work, so it waits on a person:

  > github__create_issue may already have done what it does. It began before this agent was
  > interrupted. Approve to run it again, or deny to tell the agent it may have run.

The file tools, and a tool worker's read-only or idempotent tools, run again without asking. Every
other tool asks.

### Idempotency keys

Each call has an idempotency key, the same every time the call runs:

```
acme/triage/<trace>/<span>/<round>/<call>
```

A tool with an outside effect passes the key on, so the system it calls doesn't repeat the effect
either. A payment provider, for one, takes it as its own idempotency key. A
[tool worker](/build/tool-workers/) receives it with each call.

## A history that grows

Before an agent's history outgrows what its model can read, the agent summarises the older part
with its own model and keeps the most recent part word for word. By default it summarises at 60% of
the model's context window and keeps the last 25%:

```yaml
compaction: {at: 0.5, keep: 0.2}
compaction: {window: 200000}
compaction: false
```

## Details

- **What's written when.** An agent writes each round of tool calls, each message it takes and each
  decision as they happen, and the rest of its state at least every 30 seconds. A node killed
  outright comes back from what it last wrote. Text the model had streamed but not finished isn't
  kept.
- **Stopping the daemon.** `wardrik stop` writes down what the daemon holds and waits up to a minute
  for it to stop. A turn running then comes back as a lost one does.
- **Denying an uncertain call** tells the model the call may have run, so it can find out.
- **Tool workers.** A worker that goes away mid-call, or answers late, leaves the call in doubt the
  same way.
- **The ledger's lifetime.** The daemon gives every agent the ledger, and clears a turn's claims
  once the turn ends.
- **Where the key goes.** It's in the call's `tool_call.started` event as
  `tool.call.idempotency_key`. An MCP server isn't sent it.
- **Failed turns.** Retries are covered in [Turns](/concepts/turns/#limits-on-a-turn). A failed turn
  isn't tried again: the agent goes back to `idle`, `wardrik ls` shows `idle, last failed`,
  `wardrik show` says why, and a `notify` route with `failed` says so. The next message starts a
  turn as usual.
- **Compaction.** Where the model catalog doesn't give a context window, 128,000 tokens is used. It
  happens as a turn begins, before the new messages join the history, and is reported as
  `wardrik.conversation.compacted` with message and token counts before and after. The summary is a
  model call like any other: the policy decides it, the budget counts it, stopping the turn stops
  it. If it fails, the history stays as it was and the turn runs anyway.
