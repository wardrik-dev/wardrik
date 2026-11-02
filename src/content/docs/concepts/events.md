---
title: The event stream
description: "Every action of an agent is an event. Stream them from the terminal, the HTTP API or the SDK, and resume from any point."
sidebar:
  order: 6
---

An agent emits an event for each message, model reply, tool call, approval and subagent.

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

[Events](/reference/events/) lists every type and its fields.

- Events are kept for 30 days. `sequence` counts up from 1 for each agent, with no gaps.
- Deltas, progress and `activity.changed` aren't stored. Only connected subscribers receive them.
- A turn is a trace. Its events have a W3C `traceparent`. Each tool call is a span.
- Changes people make, such as defining an agent, are in the audit log: `wardrik audit`.

## Following over HTTP

```sh
curl -N -H "authorization: Bearer $TOKEN" -H "accept: text/event-stream" \
  http://127.0.0.1:4747/v1/agents/agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN/events
```

To resume, pass the last `id:` you received as `Last-Event-ID` or `?after=`. Filters, paging and
multi-agent streams are in [Read events](/reference/http-api/#read-events).
