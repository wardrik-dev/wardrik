---
title: The event stream
description: Everything an agent does is an event on one stream, which a terminal, a webhook or the HTTP API can follow and resume.
sidebar:
  order: 4
---

Everything an agent does is an event on one stream: each message, model reply, tool call, decision
and delegation. `wardrik watch` follows it in a terminal, the HTTP API streams it, and the
terminal client is drawn from it.

```sh
wardrik watch acme/triage          # readable, until Ctrl-C
wardrik watch acme/triage --json   # one CloudEvent a line
```

## An event

Each event is a [CloudEvent](https://cloudevents.io), with what it is about under `data`:

```json
{
  "specversion": "1.0",
  "id": "0199a3c2-5f1e-7c3a-9d2b-4e8f1a6b7c90",
  "source": "wardrik://local/agents/acme/triage",
  "type": "wardrik.tool_call.started",
  "subject": "tool_calls/call_1",
  "time": "2026-10-01T12:04:01.540213Z",
  "datacontenttype": "application/json",
  "dataschema": "urn:wardrik:schema:v1:tool_call.started",
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "parentspanid": "a3ce929d0e0e4736",
  "sequence": "000000000042",
  "data": {
    "tool": {
      "name": "linear__search_issues",
      "call": {
        "id": "call_1",
        "idempotency_key": "acme/triage/4bf92f3577b34da6a3ce929d0e0e4736/00f067aa0ba902b7/1/call_1",
        "arguments": {"query": "open incidents"}
      }
    }
  }
}
```

The keys under `data` follow OpenTelemetry's names for generative AI, without their `gen_ai.`
prefix. A value longer than 64 KiB is cut short and marked `"truncated": true`.
[Events](/reference/events/) gives every type's fields.

## What happens, as events

| Events | |
| --- | --- |
| `message.created` | a message was sent to the agent |
| `run.started`, `run.completed`, `run.failed` | a turn began, answered, or failed |
| `run.interrupted`, `interrupt.resolved`, `run.resumed` | a turn parked on a person, a person decided a call, and the turn carried on |
| `run.cancelled` | a turn was stopped |
| `run.deadline_exceeded` | a turn reached its `timeout` |
| `message.started`, `message.delta`, `message.completed` | the model's reply, as it streams and in full |
| `reasoning.delta` | the model's reasoning, as it streams |
| `step.started`, `step.completed` | a step of a turn: a tool call, or a subagent's work |
| `tool_call.started`, `tool_call.completed`, `tool_call.denied`, `tool_call.progress` | a tool call, what it returned or why it was refused, and how far it has got |
| `subagent.started`, `subagent.completed`, `subagent.failed` | delegated work |
| `conversation.compacted` | the agent summarised its older history |
| `schedule.triggered` | a schedule came round, and what came of it |
| `agent.started` | the agent started on a node |

Two names are easy to misread: `run.interrupted` is a turn waiting on a person, and
`run.cancelled` is one that was stopped.

## Kept, and live

Most events are kept, in order, each with a `sequence`: a number that starts at 1 for each agent and
goes up by one with every event kept, with no gaps.

Three are live only: `message.delta`, `reasoning.delta` and `tool_call.progress`. They have no
sequence, and a client that was not connected as they happened does not see them, but each reply is
kept whole in `message.completed`.

Kept events are kept for 30 days.

## Following over HTTP

`GET /v1/agents/{key}/events`, with a token that can `read`, answers with a page of
kept events as JSON, or with a stream of every event as it happens when asked for
`text/event-stream`:

```sh
curl -N -H "authorization: Bearer $TOKEN" -H "accept: text/event-stream" \
  http://127.0.0.1:4747/v1/agents/acme/triage/events
```

```
id: 000000000042
data: {"specversion":"1.0","type":"wardrik.tool_call.started",...}

data: {"specversion":"1.0","type":"wardrik.message.delta",...}
```

A kept event's `id:` is its sequence; a live one has none. A comment line every 15 seconds keeps the
connection open.

- **From now.** With no position, the stream begins with what happens next.
- **From a position.** `Last-Event-ID`, or `?starting_after=` with a sequence, begins after that
  event, so a client that reconnects with the last `id:` it saw misses nothing kept.
- **A page.** Without `text/event-stream`, `?starting_after=` and `?limit=`, up to 500 and 100
  unless set, page through what is kept.

A position older than what is kept answers `410` with the oldest sequence there is. Read the agent
with `GET /v1/agents/{key}`, whose `sequence` is where its state was taken, and follow
from there.

The TypeScript SDK follows a stream, reconnects, and resumes from the last sequence for you. See
[Use the HTTP API](/guides/http-api/).

## Traces

A turn is a trace, and its events carry a W3C `traceparent`. The trace id is the run's id. Each tool
call is a span beneath the turn, and a subagent's work is a span beneath the call that delegated
it, with its own events beneath that, so a turn's events form a tree. `parentspanid` says which span
an event's span is beneath.

A turn that carries on after a lost node, or after a person decides, keeps its trace.

## Told rather than followed

An agent nobody is watching can tell someone when it parks, fails or answers, in Slack or with a
signed webhook. A notice is not an event: it is sent once, from the node holding the agent, to the
targets an agent file routes it to. See [Approve calls from Slack](/guides/slack/).
