---
title: "Events"
description: "The events an agent publishes, as CloudEvents, and the data each carries."
editUrl: false
sidebar:
  order: 6
---

<!-- Written by mix wardrik.docs from packages/wardrik_protocol/priv/v1. Edit it there, not here. -->

Every event is a CloudEvent: the envelope below, with the event's own data under `data`.

## The envelope

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `specversion` | `"1.0"` | yes |  |
| `id` | string | yes | A UUIDv7. |
| `source` | string | yes |  |
| `type` | string | yes |  |
| `subject` | string | yes |  |
| `time` | string (date-time) | yes |  |
| `datacontenttype` | `"application/json"` | yes |  |
| `dataschema` | string | yes |  |
| `sequence` | string |  | CloudEvents' sequence extension. Durable events only. |
| `traceparent` | string | yes |  |
| `tracestate` | string |  |  |
| `parentspanid` | string |  |  |
| `data` | object | yes |  |

## Events

### `wardrik.agent.started`

The agent was loaded: started, restarted, or moved to another node.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string |  |  |
| `agent.name` | string |  |  |
| `conversation` | object | yes |  |
| `conversation.id` | string | yes |  |
| `node` | string | yes |  |
| `status` | string | yes | One of `idle`, `running`, `parked`. |

### `wardrik.conversation.cleared`

The conversation was emptied, and with it the mark of content from outside it held.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `messages_before` | integer | yes | How many messages it held. |

### `wardrik.conversation.compacted`

The older part of the conversation was summarised.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `messages_before` | integer | yes |  |
| `messages_after` | integer | yes |  |
| `tokens_before` | integer | yes |  |
| `tokens_after` | integer | yes |  |

### `wardrik.interrupt.resolved`

A person answered an interrupt.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `interrupt` | object | yes |  |
| `interrupt.id` | string | yes |  |
| `decision` | string | yes | One of `approved`, `rejected`. |
| `reason` | string |  |  |
| `resolved_by` | [principal](#principal) |  |  |

### `wardrik.message.completed`

The model answered, failed, or was stopped.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | [message](#message) | yes |  |
| `response` | object |  |  |
| `response.model` | string |  |  |
| `response.id` | string |  |  |
| `response.finish_reasons` | array of string |  |  |
| `usage` | [usage](#usage) |  |  |
| `status` | string | yes | One of `ok`, `error`, `cancelled`. |
| `error` | [error](#error) |  |  |
| `duration_ms` | [duration_ms](#duration_ms) | yes |  |

### `wardrik.message.created`

Someone sent the agent a message, which it will answer.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | [message](#message) | yes |  |

### `wardrik.message.delta`

Text of an assistant message as it streams. Live: never stored.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | [message_ref](#message_ref) | yes |  |
| `delta` | string | yes |  |

### `wardrik.message.started`

The model was asked for an assistant message.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | [message_ref](#message_ref) | yes |  |
| `request` | object | yes |  |
| `request.model` | string | yes |  |
| `provider` | object |  |  |
| `provider.name` | string | yes |  |
| `decided` | [decided](#decided) | yes |  |

### `wardrik.reasoning.delta`

Reasoning of an assistant message as it streams. Live: never stored.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | [message_ref](#message_ref) | yes |  |
| `delta` | string | yes |  |

### `wardrik.run.cancelled`

A person stopped a run.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `run` | [run](#run) | yes |  |
| `dropped` | integer | yes |  |
| `kept` | integer | yes |  |
| `resolution` | string | yes | One of `stopped`, `killed`, `idle`, `abandoned`. |
| `duration_ms` | [duration_ms](#duration_ms) | yes |  |

### `wardrik.run.completed`

A run answered.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `run` | [run](#run) | yes |  |
| `messages` | array of [message](#message) | yes |  |

### `wardrik.run.deadline_exceeded`

A run reached its deadline and stops with what it has.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `run` | [run](#run) | yes |  |
| `message_count` | integer | yes |  |

### `wardrik.run.failed`

A run ended without answering.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `run` | [run](#run) | yes |  |
| `error` | [error](#error) | yes |  |

### `wardrik.run.interrupted`

A run stopped to wait on a person, for each interrupt it lists.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `run` | [run](#run) | yes |  |
| `interrupts` | array of [interrupt](#interrupt) | yes |  |

### `wardrik.run.resumed`

An interrupted run carried on.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `run` | [run](#run) | yes |  |

### `wardrik.run.started`

A run began, answering the messages it lists. None for a run carried on after a lost node.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `run` | [run](#run) | yes |  |

### `wardrik.schedule.triggered`

A schedule came due.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `schedule` | object | yes |  |
| `schedule.name` | string | yes |  |
| `status` | string | yes | One of `asked`, `busy`, `no_agent`, `missed`, `failed`. |

### `wardrik.step.completed`

A named step ended.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `status` | string | yes | How the step ended: cancelled where a stopped turn cut it short. One of `ok`, `error`, `cancelled`. |
| `duration_ms` | [duration_ms](#duration_ms) | yes |  |
| `error` | [error](#error) |  |  |

### `wardrik.step.started`

A named step began.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `step` | object | yes |  |
| `step.name` | string | yes |  |

### `wardrik.subagent.completed`

A subagent answered.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object |  |  |
| `agent.id` | string |  |  |
| `agent.name` | string |  |  |
| `message` | [message](#message) | yes |  |
| `duration_ms` | [duration_ms](#duration_ms) | yes |  |

### `wardrik.subagent.failed`

A subagent failed.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object |  |  |
| `agent.id` | string |  |  |
| `agent.name` | string |  |  |
| `error` | [error](#error) | yes |  |
| `duration_ms` | [duration_ms](#duration_ms) | yes |  |

### `wardrik.subagent.started`

A subagent was handed a task.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object |  |  |
| `agent.id` | string |  |  |
| `agent.name` | string |  |  |
| `prompt` | string | yes |  |

### `wardrik.tool_call.completed`

A tool call answered, or was answered from the ledger when replayed.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `tool` | [tool](#tool) | yes |  |
| `status` | string | yes | One of `ok`, `error`. |
| `error` | [error](#error) |  |  |
| `replayed` | boolean | yes |  |
| `served_by` | [served_by](#served_by) |  |  |

### `wardrik.tool_call.denied`

A tool call was refused without running.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `tool` | [tool](#tool) | yes |  |
| `reason` | string | yes |  |
| `decided` | [decided](#decided) | yes |  |

### `wardrik.tool_call.progress`

A tool call reported progress. Live: never stored.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `tool` | [tool](#tool) | yes |  |
| `progress` | number | yes |  |
| `total` | number |  |  |

### `wardrik.tool_call.started`

A tool call began.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `tool` | [tool](#tool) | yes |  |
| `decided` | [decided](#decided) | yes |  |

## Shared types

The types events and resources refer to.

### `message`

A message in OpenTelemetry's GenAI shape. On message.started and message.delta only its id is given.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string |  |  |
| `role` | string |  | system, user, assistant or tool. |
| `name` | string |  |  |
| `parts` | array of [part](#part) | yes |  |

### `message_ref`

A message, by its id.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | yes |  |

### `part`

One part of a message, tagged by type, as OpenTelemetry's GenAI conventions define them.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `type` | string | yes | text, reasoning, tool_call, tool_call_response, uri, file or blob. |
| `content` | string |  |  |
| `id` | string |  |  |
| `name` | string |  |  |
| `arguments` | any |  | Any JSON value. Stored as a flattened field. |
| `response` | any |  | Any JSON value. Stored as a flattened field. |
| `modality` | string |  | One of `image`, `video`, `audio`, `document`. |
| `mime_type` | string |  |  |
| `uri` | string |  |  |
| `file_id` | string |  |  |
| `truncated` | boolean |  |  |

### `error`

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `type` | string | yes | A low-cardinality code, as OpenTelemetry's error.type. |
| `message` | string | yes |  |

### `usage`

Token usage, as gen_ai.usage.* without the prefix.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `input_tokens` | integer |  |  |
| `output_tokens` | integer |  |  |
| `cache_read` | object |  |  |
| `cache_read.input_tokens` | integer |  |  |
| `reasoning` | object |  |  |
| `reasoning.output_tokens` | integer |  |  |
| `cost_usd` | number |  |  |

### `principal`

Who decided.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `type` | string | yes | shell, ssh, terminal, slack, oauth or token. |
| `id` | string | yes |  |
| `name` | string |  |  |

### `decided`

Who decided a call.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `by` | string | yes | hook where hooks allowed the call by name or one refused it, person where a person answered it, default where no hook named it and nothing asked, ledger where the ledger could not record it. One of `hook`, `person`, `default`, `ledger`. |
| `hooks` | array of string |  | The hooks that allowed the call, refused it, or asked a person about it. |

### `served_by`

What answered a tool call, as its tool names it: a tool worker's token, for one.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | yes |  |
| `name` | string |  |  |

### `run`

A run, by the W3C trace id it runs under.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | yes |  |
| `message_ids` | array of string |  |  |

### `tool`

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `name` | string | yes |  |
| `type` | string |  |  |
| `call` | object | yes |  |
| `call.id` | string | yes |  |
| `call.arguments` | any |  | Any JSON value. Stored as a flattened field. |
| `call.result` | any |  | Any JSON value. Stored as a flattened field. |
| `call.idempotency_key` | string |  |  |
| `call.truncated` | boolean |  |  |

### `duration_ms`

No fields.

### `interrupt`

A call a run waits on a person for.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `id` | string | yes |  |
| `reason` | string | yes | One of `tool_approval`, `model_approval`, `authorization`, `in_doubt`. |
| `message` | string | yes |  |
| `tool_call_id` | string |  |  |
| `labels` | array of string |  | The labels of what the run had read, which may be what asked for the call: outside for content nobody on the agent's side wrote. |
