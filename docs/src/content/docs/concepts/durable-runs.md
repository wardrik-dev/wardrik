---
title: Durable runs
description: How a turn carries on when its node is lost, how the ledger keeps a tool call from running twice, and how an agent's history stays within what its model can read.
sidebar:
  order: 2
---

An agent's state is written to the store as it changes: its conversation, the messages waiting for
it, and what it is doing. So whichever node holds the agent next, after a restart or a lost node,
carries on from there.

## A turn lost part way

Before a turn runs a round of tool calls, the agent writes the round to the store, and the calls run
only once it is written. A turn whose node is lost comes back on another node at that round, with
the same calls, rather than asking the model again and paying for an answer that may differ.

What comes back depends on what was last written:

| When the node was lost | What happens |
| --- | --- |
| The agent was waiting on a person | It waits on the same calls |
| A round of tool calls was running | The round runs again, through the ledger |
| The model was answering, before any tool call | The turn starts again |

Text the model had streamed but not finished is not kept.

## The ledger

Running a round again would repeat whatever its calls did, so every call is claimed in the ledger
before it runs and settled after, in the store. When a round runs again, the ledger decides each
call:

- **A call that finished** is answered with what it returned, without running. Its
  `tool_call.completed` event says `"replayed": true`.
- **A call that began and never finished** may have done what it does. It waits on a person:

  > github__create_issue began before this agent was interrupted, and may already have done what it
  > does. Approve to run it again, or deny to tell the agent it may have run.

  Denying tells the model the call may have run, so it can find out.

The file tools run again without asking, since each finds a write it made already, and so do a tool
worker's tools where the worker marks them read-only or idempotent. Every other tool asks.

The daemon gives every agent the ledger, and clears a turn's claims once the turn ends.

### Idempotency keys

Each call has an idempotency key, the same each time the call runs:

```
acme/_/triage/<trace>/<span>/<round>/<call>
```

A tool with an effect outside Wardrik passes the key on, so the system it calls does not repeat the
effect either: a payment provider, for one, takes it as its own idempotency key. A tool worker
receives it with each call; see [Tools in your app](/guides/tool-workers/). It is in the call's
`tool_call.started` event as `tool.call.idempotency_key`.

An MCP server is not sent the key.

## Stopping and starting

`wardrik stop` writes down what the daemon holds and waits, up to a minute, for it to stop. A turn
running when it stops comes back as a lost one does, when the daemon starts again.

A node killed outright, with `kill -9` or by losing its machine, comes back from what it last wrote.
An agent writes each round of tool calls, each message it takes and each decision on its calls as
it takes them, and the rest of its state at least every 30 seconds.

## When something fails

A model call that fails before the provider begins to answer, for a reason that may pass, such as a
timeout, a dropped connection, a rate limit or a 5xx, is tried again after one second and again
after five. Anything else fails the turn.

A failed turn is not tried again. The agent goes back to `idle`, `wardrik ls` shows
`idle, last failed`, `wardrik show` says why, and a `notify` route with `failed` says so. The next
message starts a turn as usual.

## A history that grows

An agent that runs for weeks keeps adding to one conversation. Before it outgrows what the model can
read, the agent summarises the older part with its own model and keeps the most recent part word
for word.

By default it summarises once its history reaches 60% of the model's context window, as the model
catalog gives it, or of 128,000 tokens where the catalog does not say, and keeps the last 25%. An
agent file sets other amounts, or none:

```yaml
compaction: {at: 0.5, keep: 0.2}
compaction: {window: 200000}
compaction: false
```

It happens between turns, before the turn that would outgrow it, and is reported as
`wardrik.conversation.compacted`, with how many messages and tokens there were before and after. The
summary is a model call like any other, so the agent's policy decides it and its budget counts it.
If it fails, the history stays as it was and the turn runs regardless.
