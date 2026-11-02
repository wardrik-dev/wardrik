---
title: "Events"
description: "The events an agent writes to its log, as CloudEvents, and the data each carries."
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
- Every event is a CloudEvent. Its own fields are under `data`.
- **Live** events stream as they happen and are never stored.
- Each `data` schema is in `wardrik_protocol`'s `priv/v1/`, named as `dataschema` says.

## Envelope

| Field | Type | Description |
| --- | --- | --- |
| `specversion` | `"1.0"` | |
| `id` | string | a UUIDv7 |
| `source` | string | `wardrik://DEPLOYMENT/agents/AGENT`, or `wardrik://DEPLOYMENT/audit` for a change people made |
| `type` | string | the event type, below |
| `subject` | string | what it's about, as `agents/AGENT` |
| `time`, `datacontenttype`, `dataschema` | string | |
| `sequence` | string | its place in the agent's log; stored events only |
| `agent` | string | the agent's ID |
| `conversation` | string | the conversation's ID; absent for the agent's main conversation |
| `traceparent`, `tracestate`, `parentspanid` | string | W3C trace context; the trace ID is the run's ID |
| `data` | object | the event's fields |

## Runs and messages

| Type | `data` | When |
| --- | --- | --- |
| `wardrik.run.started` | `run` | a run began |
| `wardrik.run.completed` | `run`, `messages` | a run answered |
| `wardrik.run.failed` | `run`, `error` | a run ended without answering |
| `wardrik.run.cancelled` | `run`, `dropped`, `kept`, `resolution`, `duration_ms` | a person stopped a run; `resolution` is `stopped`, `killed`, `idle` or `abandoned` |
| `wardrik.run.interrupted` | `run`, `interrupts` | a run waits on a person |
| `wardrik.run.resumed` | `run` | an interrupted run carried on |
| `wardrik.run.deadline_exceeded` | `run`, `message_count` | a run hit its deadline |
| `wardrik.message.created` | `message`, `sender?` | someone sent the agent a message |
| `wardrik.message.started` | `message`, `request`, `provider?`, `decided` | the model was asked |
| `wardrik.message.delta` | `message`, `delta` | text as it streams. **Live** |
| `wardrik.reasoning.delta` | `message`, `delta` | reasoning as it streams. **Live** |
| `wardrik.message.retrying` | `message`, `attempt`, `attempts`, `wait_ms`, `error` | the model failed and is asked again |
| `wardrik.message.completed` | `message`, `status`, `duration_ms`, `response?`, `usage?`, `cost?`, `error?` | the model answered (`ok`), failed (`error`) or was stopped (`cancelled`) |
| `wardrik.step.started` | `step` | a named step began |
| `wardrik.step.completed` | `status`, `duration_ms`, `error?` | a named step ended |
| `wardrik.activity.changed` | `activity` | what the agent is doing changed. **Live** |

`?` marks a field that may be absent.

## Tool calls

| Type | `data` | When |
| --- | --- | --- |
| `wardrik.tool_call.started` | `tool`, `decided` | a tool call began |
| `wardrik.tool_call.progress` | `tool`, `progress`, `total?` | a tool reported progress. **Live** |
| `wardrik.tool_call.retrying` | `tool`, `attempt`, `attempts`, `wait_ms`, `error` | a call that may run twice crashed or timed out, and runs again |
| `wardrik.tool_call.completed` | `tool`, `status`, `replayed`, `error?`, `served_by?`, `cost?` | a tool call answered |
| `wardrik.tool_call.denied` | `tool`, `reason`, `decided` | a call was refused without running |
| `wardrik.interrupt.resolved` | `interrupt`, `decision`, `reason?`, `note?`, `resolved_by?` | a person approved or rejected a call |
| `wardrik.call.killed` | `agent`, `call` | someone stopped a running tool call |
| `wardrik.subagent.started` | `agent?`, `prompt` | a subagent was handed a task |
| `wardrik.subagent.progress` | `agent`, `tool`, `tool_calls` | a subagent began a tool call. **Live** |
| `wardrik.subagent.completed` | `agent?`, `message`, `duration_ms`, `tool_calls?`, `usage?`, `cost?` | a subagent answered |
| `wardrik.subagent.failed` | `agent?`, `error`, `duration_ms`, `tool_calls?`, `usage?`, `cost?` | a subagent failed |

## Agents and conversations

Events someone caused also carry `actor?` and `assumed_by?`: who did it, and who acted for them.

| Type | `data` | When |
| --- | --- | --- |
| `wardrik.agent.defined` | `agent` | someone wrote the agent's definition |
| `wardrik.agent.spawned` | `agent`, `node` | someone started the agent |
| `wardrik.agent.started` | `agent`, `node`, `status`, `conversation?` | the agent was loaded: started, restarted or moved |
| `wardrik.agent.stopped` | `agent`, `node?`, `reason?` | the agent stopped; `reason: "idle"` if it went to sleep itself |
| `wardrik.agent.moved` | `agent`, `node` | someone moved the agent to another node |
| `wardrik.agent.cancelled` | `agent`, `resource?` | someone dropped its turn and queue |
| `wardrik.agent.cleared` | `agent` | someone emptied its conversation |
| `wardrik.agent.forgotten` | `agent`, `resource?` | someone removed the agent |
| `wardrik.agents.reloaded` | `nodes` | someone reloaded the agent files |
| `wardrik.conversation.cleared` | `messages_before` | the conversation was emptied |
| `wardrik.conversation.compacted` | `messages_before`, `messages_after`, `tokens_before`, `tokens_after` | older history was summarised |
| `wardrik.trigger.set` | `agent`, `trigger` | someone set a trigger |
| `wardrik.trigger.removed` | `agent`, `trigger` | someone removed a trigger |
| `wardrik.trigger.fired` | `trigger`, `status` | a trigger came due; `status` is `asked`, `nothing_new`, `busy`, `no_agent`, `missed` or `failed` |
| `wardrik.room.bound` | `channel`, `room`, `agent`, `answers` | an agent now answers in a chat room, on `mentions` or `everything` |
| `wardrik.room.unbound` | `channel`, `room` | the agent in a room stopped answering |
| `wardrik.events.dropped` | `after`, `oldest` | the log was trimmed past your cursor; sent to you alone, never stored |

## Daemon changes

Written to the audit log. Each also carries `actor?` and `assumed_by?`. `owner` is `acme`, `acme/@jon` or `deployment`.

| Type | `data` |
| --- | --- |
| `wardrik.secret.stored`, `wardrik.secret.removed` | `secret`, `owner?` (absent for the deployment's) |
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
| `activity` | `doing` (what it's doing, each by the event type that set it), `since`, `pending` |
| `spent` | `tokens`, `usd`, for today (UTC) |
| `duration_ms` | integer |
