---
title: Turns
description: "An agent answers in turns: it asks the model, runs the tool calls the model makes, and asks again until the model answers."
sidebar:
  order: 1.1
---

An agent answers in turns. A turn works like this:

1. It takes the messages waiting, and asks the model.
2. It runs the tool calls the model makes.
3. It asks the model again, with their results.
4. It ends when the model answers without calling anything.

A tool call may wait on a person, which parks the turn until it is decided. See
[Approvals](/concepts/approvals/).

## Messages wait their turn

The messages waiting when a turn begins are answered together. One that arrives during a turn asks
it to stop at its next step. The next turn answers the new message with everything the last one
left.

## Limits on a turn

| Setting | Default | At the limit |
| --- | --- | --- |
| `max_iterations` | 25 rounds of tool calls | the turn fails |
| `timeout` | none | the turn stops at its next step, as `run.deadline_exceeded` |
| `retries` | 6 more tries, waiting up to 60 seconds | a person is asked whether to try again |

Set them in the [agent file](/reference/agent-files/), or for every agent in `config.yaml`'s
`defaults`. Up to 8 of a round's tool calls run at once, each for up to 3 minutes unless its tool
says otherwise.

## Stopping a turn

```sh
wardrik agent cancel triage                # acme/triage
wardrik agent cancel 'acme/@jon/agent/*'   # every agent of jon's
wardrik agent cancel --all                 # every agent there is
```

Cancelling stops the running turn, drops the messages waiting behind it, and abandons a parked one.
The agent itself keeps running and answers the next message. `POST /v1/agents/{agent}/cancel` does
the same.

`wardrik agent kill AGENT CALL` stops one tool call instead. The model is told it failed, and the
turn goes on. `wardrik agent calls AGENT` lists the calls running.

## The conversation

An agent keeps everything said to it and by it. `wardrik agent history AGENT` prints it. The system
prompt, the body of the agent's file, isn't part of it. It's put in front of every turn, so a change
applies from the next turn.

`wardrik agent clear AGENT` empties the conversation, keeping files, triggers and the definition.
It's also how an agent is rid of [content from outside](/concepts/outside-content/).

## Subagents

`deep_research` hands a question to subagents. Several researchers work at once, each with a turn
of its own, and the agent combines what they found. A subagent:

- has its caller's tools, except `deep_research`;
- has no conversation of its own;
- can't wait on a person, so a call that would ask one is refused.

## Details

- **Retries.** A failed model call is tried again after a random wait that doubles each time, or as
  long as the provider's `Retry-After` says. A 4xx other than 408, 425 and 429 isn't tried again.
  Each try is announced with `message.retrying`. Once the tries are spent, the turn waits on a
  person, unless [`retries`](/reference/agent-files/#retries) says `on_exhausted: fail`.
- **Stopping the daemon.** `wardrik stop` stops the daemon, and every agent with it.
- **Clearing.** `wardrik agent clear` refuses while the agent runs a turn or waits on a person.
- **Long histories.** An agent that runs for weeks summarises its older history; see
  [A history that grows](/concepts/durable-runs/#a-history-that-grows).
- **Subagent events.** A subagent's work appears in its caller's event stream as
  `subagent.started`, `subagent.progress`, and `subagent.completed` or `subagent.failed`. The last
  two carry what it did and cost; its own events aren't kept. What its researchers read labels
  the answer, as reading it directly would.
- **Other agents.** For delegating to agents of the org, with their own conversations, see
  [Delegate to other agents](/build/delegation/).
