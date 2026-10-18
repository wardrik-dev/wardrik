---
title: Turns
description: "An agent answers in turns: it asks the model, runs the tool calls the model makes, and asks again until the model answers."
sidebar:
  order: 1.1
---

An agent answers in turns. A turn takes the messages waiting, asks the model, runs the tool calls
the model makes, and asks the model again with their results. It ends when the model answers
without calling anything.

A tool call may wait on a person, which parks the turn until it is decided. See
[Approvals](/concepts/approvals/).

## Messages wait their turn

The messages waiting when a turn begins are answered together. One that arrives during a turn asks
it to stop at its next step. The next turn answers the new message with everything the last one
left.

## Limits on a turn

| Setting | Default | At the limit |
| --- | --- | --- |
| `max_iterations` | 30 rounds of tool calls | the model is asked once more, without tools, to answer |
| `timeout` | none | the turn stops at its next step, as `run.deadline_exceeded` |
| `retries` | 6 more tries, waits up to 60 seconds | a person is asked whether to try again |

Set them in the [agent file](/reference/agent-files/), or for every agent in `config.yaml`'s
`defaults`. Up to 8 of a round's tool calls run at once, each for up to 60 seconds.

## Stopping a turn

```sh
wardrik agent cancel triage       # acme/triage
wardrik agent cancel acme/@jon/   # every agent of jon's
wardrik agent cancel --all        # every agent there is
```

Cancelling stops the running turn, drops the messages waiting behind it, and abandons a parked one.
The agent itself keeps running and answers the next message. `POST /v1/agents/{key}/cancel` and
`/stop` in the [terminal client](/build/tui/) do the same.

## The conversation

An agent keeps everything said to it and by it; `wardrik history` prints it. The system prompt, the
body of the agent's file, isn't part of it: it's put in front of every turn, so a change applies
from the next turn.

`wardrik clear AGENT` empties the conversation, keeping files, triggers and config. It's also how
an agent is rid of [content from outside](/concepts/outside-content/).

## Subagents

`deep_research` hands a question to subagents: several researchers at once, each with a turn of its
own, and one more to bring what they found together. A subagent has its caller's tools, has no
conversation of its own, and can't wait on a person: a call that would ask one is refused.

## Details

- **Retries.** A failed model call is tried again after a random wait that doubles each time, or as
  long as the provider's `Retry-After` says. A 4xx other than 408, 425 and 429 isn't tried again.
  Each try is announced with `message.retrying`. What a failed try had streamed is dropped, and the
  next try answers as a message of its own. Once the tries are spent the turn waits on a person,
  unless [`retries`](/reference/agent-files/#retries) says `on_exhausted: fail`.
- **Stopping.** A turn that stops within two seconds keeps what it said; one that doesn't is ended
  and adds nothing. A stopped turn stays stopped on whichever node holds the agent next.
  `wardrik stop` stops the daemon, and every agent with it.
- **Clearing.** `wardrik clear` refuses while the agent runs a turn or waits on a person.
- **Long histories.** An agent that runs for weeks summarises its older history; see
  [A history that grows](/concepts/durable-runs/#a-history-that-grows).
- **Subagents.** A subagent that reads content from outside marks the call that ran it, as reading
  it directly would. Its work appears in its caller's event stream as `subagent.started`,
  `subagent.completed` and `subagent.failed`, with its own events beneath them. An application using
  Wardrik as a library delegates with `Wardrik.Subagent.run/3`, from a tool or a workflow.
- **Other agents.** For delegating to agents of the org, with their own conversations, see
  [Delegate to other agents](/build/delegation/).
