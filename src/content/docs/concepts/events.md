---
title: The event stream
description: "Everything an agent does is an event, which the terminal, the HTTP API, the SDK or Elixir can follow and resume."
sidebar:
  order: 6
---

Everything an agent does is an event: each message, model reply, tool call, decision and
subagent.

```sh
wardrik follow triage          # readable, until Ctrl-C
wardrik follow triage --json   # one CloudEvent a line
```

## An event

Each event is a [CloudEvent](https://cloudevents.io):

```json
{
  "specversion": "1.0",
  "id": "0199a3c2-5f1e-7c3a-9d2b-4e8f1a6b7c90",
  "source": "wardrik://local/agents/agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN",
  "type": "wardrik.tool_call.started",
  "subject": "tool_calls/call_1",
  "time": "2026-10-01T12:04:01.540213Z",
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "sequence": "000000000042",
  "data": {"tool": {"name": "linear__search_issues", "call": {"id": "call_1", "arguments": {"query": "open incidents"}}}}
}
```

| Events | Mean |
| --- | --- |
| `message.created` | a message was sent to the agent |
| `run.started`, `run.completed`, `run.failed` | a turn began, answered, or failed |
| `run.interrupted`, `interrupt.resolved`, `run.resumed` | a turn waited on a person, who decided, and it went on |
| `run.cancelled`, `run.deadline_exceeded` | a turn was stopped, or ran past its `timeout` |
| `message.delta`, `message.completed` | the model's reply, streaming and whole |
| `tool_call.started`, `tool_call.completed`, `tool_call.denied` | a tool call, its result, or its refusal |
| `subagent.started`, `subagent.completed`, `subagent.failed` | a subagent's work |
| `agent.started`, `agent.stopped` | the agent started on a node, or stopped |
| `activity.changed` | what the agent is doing now |

[Events](/reference/events/) lists every type and its fields.

- Events are kept for 30 days. `sequence` counts up from 1 for each agent, with no gaps.
- Deltas, progress and `activity.changed` are live only. A reader that wasn't connected misses them.
- A turn is a trace. Its events carry a W3C `traceparent`. Each tool call is a span.
- What people change, such as defining an agent, is in the audit: `wardrik audit`.

## Following over HTTP

```sh
curl -N -H "authorization: Bearer $TOKEN" -H "accept: text/event-stream" \
  http://127.0.0.1:4747/v1/agents/agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN/events
```

- To resume, send the last `id:` you saw as `Last-Event-ID`, or as `?after=`.
- `?types=wardrik.run.completed` reads only those types.
- Without `text/event-stream`, the route answers a page of JSON, with `next`.
- `GET /v1/events?agents=agt_1&agents=agt_2` follows several agents at once.
- A conversation's events are at `/v1/agents/{agent}/conversations/{conversation}/events`.

## In Elixir

```elixir
WardrikEvents.activity(MyApp.Events, "agt_1")            # the agent's main conversation
WardrikEvents.activity(MyApp.Events, {"agt_1", "C1"})    # one conversation
```

See `WardrikEvents` for `page/3`, `stream/3` and `subscribe/2`.
