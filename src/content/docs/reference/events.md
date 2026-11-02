---
title: "Events"
description: "The CloudEvents an agent writes to its log, and each event's data fields."
sidebar:
  order: 6
---

```json
{
  "specversion": "1.0",
  "id": "0192b7e4-6c1a-7d3e-9f00-1a2b3c4d5e6f",
  "source": "wardrik://acme-prod/agents/agt_01JF8X5RQ2",
  "type": "wardrik.run.completed",
  "subject": "agents/agt_01JF8X5RQ2",
  "time": "2026-10-22T09:00:04Z",
  "datacontenttype": "application/json",
  "dataschema": "urn:wardrik:schema:v1:run.completed",
  "sequence": "000000000042",
  "agent": "agt_01JF8X5RQ2",
  "conversation": "C1",
  "traceparent": "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "data": {"run": {"id": "4bf92f3577b34da6a3ce929d0e0e4736"}, "messages": []}
}
```

- Read them with [`GET /v1/events`](/reference/http-api/#read-events) or `wardrik agent follow AGENT --json`.
- Every event is a CloudEvent. Event-specific fields are under `data`.
- **Live** events are streamed but never stored.
- Each `data` schema is in `wardrik_protocol`'s `priv/v1/`, named by `dataschema`.

## Envelope

| Field | Type | Description |
| --- | --- | --- |
| `specversion` | `"1.0"` | |
| `id` | string | a UUIDv7 |
| `source` | string | `wardrik://DEPLOYMENT/agents/AGENT`, or `wardrik://DEPLOYMENT/audit` for audit events |
| `type` | string | the event type, below |
| `subject` | string | the resource, as `agents/AGENT` |
| `time`, `datacontenttype`, `dataschema` | string | |
| `sequence` | string | position in the agent's log; stored events only |
| `agent` | string | the agent's ID |
| `conversation` | string | the conversation's ID; absent for the agent's main conversation |
| `traceparent`, `tracestate`, `parentspanid` | string | W3C trace context; the trace ID is the turn's ID |
| `data` | object | the event's fields |

## Runs and messages

| Type | `data` | When |
| --- | --- | --- |
| `wardrik.run.started` | `run` | a turn started |
| `wardrik.run.completed` | `run`, `messages` | a turn completed with a reply |
| `wardrik.run.failed` | `run`, `error` | a turn ended without a reply |
| `wardrik.run.cancelled` | `run`, `dropped`, `kept`, `resolution`, `duration_ms` | a turn was cancelled; `resolution` is `stopped`, `killed`, `idle` or `abandoned` |
| `wardrik.run.interrupted` | `run`, `interrupts` | a turn paused for approval |
| `wardrik.run.resumed` | `run` | a paused turn resumed |
| `wardrik.run.deadline_exceeded` | `run`, `message_count` | a turn exceeded its `timeout` |
| `wardrik.message.created` | `message`, `sender?` | a message was sent to the agent |
| `wardrik.message.started` | `message`, `request`, `provider?`, `decided` | a model call started |
| `wardrik.message.delta` | `message`, `delta` | text as it streams. **Live** |
| `wardrik.reasoning.delta` | `message`, `delta` | reasoning as it streams. **Live** |
| `wardrik.message.retrying` | `message`, `attempt`, `attempts`, `wait_ms`, `error` | a model call failed and will be retried |
| `wardrik.message.completed` | `message`, `status`, `duration_ms`, `response?`, `usage?`, `cost?`, `error?` | a model call returned (`ok`), failed (`error`) or was cancelled (`cancelled`) |
| `wardrik.step.started` | `step` | a named step started |
| `wardrik.step.completed` | `status`, `duration_ms`, `error?` | a named step ended |
| `wardrik.activity.changed` | `activity` | the agent's activity changed. **Live** |

`?` marks a field that may be absent.

## Tool calls

| Type | `data` | When |
| --- | --- | --- |
| `wardrik.tool_call.started` | `tool`, `decided` | a tool call started |
| `wardrik.tool_call.progress` | `tool`, `progress`, `total?` | a tool reported progress. **Live** |
| `wardrik.tool_call.retrying` | `tool`, `attempt`, `attempts`, `wait_ms`, `error` | a retry-safe call crashed or timed out, and will be retried |
| `wardrik.tool_call.completed` | `tool`, `status`, `replayed`, `error?`, `served_by?`, `cost?` | a tool call returned |
| `wardrik.tool_call.denied` | `tool`, `reason`, `decided` | a call was denied without running |
| `wardrik.interrupt.resolved` | `interrupt`, `decision`, `reason?`, `note?`, `resolved_by?` | a pending call was approved or denied |
| `wardrik.call.killed` | `agent`, `call` | a running tool call was stopped |
| `wardrik.subagent.started` | `agent?`, `prompt` | a subagent started a task |
| `wardrik.subagent.progress` | `agent`, `tool`, `tool_calls` | a subagent started a tool call. **Live** |
| `wardrik.subagent.completed` | `agent?`, `message`, `duration_ms`, `tool_calls?`, `usage?`, `cost?` | a subagent returned |
| `wardrik.subagent.failed` | `agent?`, `error`, `duration_ms`, `tool_calls?`, `usage?`, `cost?` | a subagent failed |

## Agents and conversations

Events caused by a request also have `actor?` and `assumed_by?`: the caller, and the chain it acted through.

| Type | `data` | When |
| --- | --- | --- |
| `wardrik.agent.defined` | `agent` | the definition was written |
| `wardrik.agent.spawned` | `agent`, `node` | the agent was started by a request |
| `wardrik.agent.started` | `agent`, `node`, `status`, `conversation?` | the agent's process started, restarted or moved |
| `wardrik.agent.stopped` | `agent`, `node?`, `reason?` | the process stopped; `reason: "idle"` after `idle_timeout` |
| `wardrik.agent.moved` | `agent`, `node` | the agent was moved to another node |
| `wardrik.agent.cancelled` | `agent`, `resource?` | the turn and queue were dropped |
| `wardrik.agent.cleared` | `agent` | the conversation was cleared |
| `wardrik.agent.forgotten` | `agent`, `resource?` | the agent was removed |
| `wardrik.agents.reloaded` | `nodes` | agent files were reloaded |
| `wardrik.conversation.cleared` | `messages_before` | the conversation was cleared |
| `wardrik.conversation.compacted` | `messages_before`, `messages_after`, `tokens_before`, `tokens_after` | older history was summarised |
| `wardrik.trigger.set` | `agent`, `trigger` | a trigger was set |
| `wardrik.trigger.removed` | `agent`, `trigger` | a trigger was removed |
| `wardrik.trigger.fired` | `trigger`, `status` | a trigger ran; `status` is `asked`, `nothing_new`, `busy`, `no_agent`, `missed` or `failed` |
| `wardrik.room.bound` | `channel`, `room`, `agent`, `answers` | a chat room was bound to an agent, replying on `mentions` or `everything` |
| `wardrik.room.unbound` | `channel`, `room` | a chat room was unbound |
| `wardrik.events.dropped` | `after`, `oldest` | the log was trimmed past your cursor; sent only to you, never stored |

## Daemon changes

Written to the audit log. Each also has `actor?` and `assumed_by?`. `owner` is `acme`, `acme/@jon` or `deployment`.

| Type | `data` |
| --- | --- |
| `wardrik.secret.stored`, `wardrik.secret.removed` | `secret`, `owner?` (absent for deployment secrets) |
| `wardrik.server.added`, `wardrik.server.removed` | `server`, `owner` |
| `wardrik.notify_target.added`, `wardrik.notify_target.removed` | `notify_target`, `owner` |
| `wardrik.provider.added`, `wardrik.provider.removed` | `provider`, `owner` |

## Shared types

| Type | Fields |
| --- | --- |
| `run` | `id` (its W3C trace ID), `message_ids?` |
| `message` | `id?`, `role?` (`system`, `user`, `assistant`, `tool`), `name?`, `parts` |
| `message_ref` | `id` |
| `part` | `type` (`text`, `reasoning`, `tool_call`, `tool_call_response`, `uri`, `file`, `blob`), `content?`, `id?`, `name?`, `arguments?`, `response?`, `modality?`, `mime_type?`, `uri?`, `file_id?`, `truncated?` |
| `tool` | `name`, `type?`, `call` |
| `interrupt` | `id`, `reason` (`tool_approval`, `model_approval`, `ceiling_approval`, `authorization`, `in_doubt`), `message`, `tool_call_id?`, `name?`, `labels?` |
| `decided` | `by` (`hook`, `person`, `default`, `ledger`), `hooks?` |
| `error` | `type`, `message` |
| `usage` | `input_tokens?`, `output_tokens?`, `cache_read?`, `reasoning?` |
| `cost` | `micro_usd` (1000000 is one dollar), `source` (`provider`, `catalog`, `tool`) |
| `principal` | `id`, `name?` |
| `assumed_by` | a list of `principal`, first to last |
| `served_by` | `id`, `name?` |
| `activity` | `doing` (current activities, each keyed by the event type that set it), `since`, `pending` |
| `spent` | `tokens`, `usd`, for today (UTC) |
| `duration_ms` | integer |
