---
title: The event stream
description: "Everything an agent does is an event on one stream, which a terminal, the HTTP API or the SDK can follow and resume."
sidebar:
  order: 4
---

Everything an agent does is an event on one stream: each message, model reply, tool call, decision
and delegation. Follow it in a terminal:

```sh
wardrik watch acme/triage          # readable, until Ctrl-C
wardrik watch acme/triage --json   # one CloudEvent a line
```

## An event

Each event is a [CloudEvent](https://cloudevents.io), with what it's about under `data`:

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

[Events](/reference/events/) lists every type's fields.

## What happens, as events

| Events | |
| --- | --- |
| `message.created` | a message was sent to the agent |
| `run.started`, `run.completed`, `run.failed` | a turn began, answered, or failed |
| `run.interrupted`, `interrupt.resolved`, `run.resumed` | a turn waited on a person, a person decided, and the turn carried on |
| `run.cancelled` | a turn was stopped |
| `run.deadline_exceeded` | a turn reached its `timeout` |
| `message.started`, `message.delta`, `message.completed` | the model's reply, streaming and in full |
| `reasoning.delta` | the model's reasoning, streaming |
| `step.started`, `step.completed` | a step of a turn other than a tool call, such as summarising its history, or a subagent's work |
| `tool_call.started`, `tool_call.completed`, `tool_call.denied`, `tool_call.progress` | a tool call, its result or refusal, and its progress |
| `subagent.started`, `subagent.completed`, `subagent.failed` | delegated work |
| `conversation.compacted`, `conversation.cleared` | the history was summarised, or emptied |
| `trigger.fired` | a trigger came round, and what came of it |
| `agent.started` | the agent started on a node |
| `activity.changed` | what the agent is doing now: thinking, running tools, retrying, waiting on a person |

`run.interrupted` means a turn is waiting on a person; `run.cancelled` means it was stopped.

## Kept, and live

Most events are kept for 30 days, each with a `sequence` that starts at 1 for each agent and goes up
by one, with no gaps. Four are live only, with no sequence: `message.delta`, `reasoning.delta`,
`tool_call.progress` and `activity.changed`. A client that wasn't connected misses them, but each
reply is kept whole in `message.completed`, and the agent's snapshot says what it is doing.

## Following over HTTP

```sh
curl -N -H "authorization: Bearer $TOKEN" -H "accept: text/event-stream" \
  http://127.0.0.1:4747/v1/agents/acme/triage/events
```

```
id: eyJhY21lL2FnZW50L3RyaWFnZSI6NDJ9
data: {"specversion":"1.0","type":"wardrik.tool_call.started",...}

data: {"specversion":"1.0","type":"wardrik.message.delta",...}
```

The stream begins with what happens next. To resume, send the last `id:` you saw as
`Last-Event-ID`, or `?after=`, and you miss nothing kept. `GET /v1/events?resources=acme/agent/*`
follows every agent a pattern covers the same way. The TypeScript SDK reconnects and resumes for
you; see [Use the HTTP API](/build/http-api/).

## Traces

A turn is a trace: its events carry a W3C `traceparent`, and the trace id is the run's id. Each tool
call is a span beneath the turn, and a subagent's work a span beneath the call that delegated it.
A tool call's own events open and close its span: `tool_call.started`, or `tool_call.denied` for a
call that never ran, opens it, and `tool_call.completed` or `tool_call.denied` closes it. A call
waiting on a person is listed in the turn's `run.interrupted`. A turn that carries on after a lost
node, or after a person decides, keeps its trace.

## Details

- **Other readers.** The HTTP API streams the same events, and the terminal client is drawn from
  them.
- **Field names.** The keys under `data` follow OpenTelemetry's names for generative AI, without
  their `gen_ai.` prefix. A value longer than 64 KiB is cut short and marked `"truncated": true`.
- **The stream over HTTP** needs a token that can `read`. An event's `id:` is a cursor, where you
  are in each agent's log; a live one that moves nothing has none. Wardrik keeps no reader's
  place: keep the last `id:` yourself. A comment line every 15 seconds keeps the connection open.
- **Pages.** Without `text/event-stream`, the route answers a page of kept events as JSON, with
  `next`, the cursor after them. `?after=` and `?limit=` (100 unless set, up to 500) page through
  them.
- **Too old.** Where a log was trimmed past your cursor, a `wardrik.events.dropped` event names
  the sequence you were after and the oldest kept, and reading goes on from there. An agent's
  snapshot, `GET /v1/agents/{key}`, has the `cursor` its state was taken at.
- **Span tree.** `parentspanid` says which span an event's span is beneath, so a turn's events form
  a tree.
- **Notices aren't events.** An agent can tell someone when it parks, fails or answers, in Slack or
  with a signed webhook. One node of the cluster reads the events and sends each notice to the
  targets the agent's file routes to. See [Send notices](/build/notices/).
