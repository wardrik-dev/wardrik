---
title: "Events"
description: "The events an agent publishes, as CloudEvents, and the data each carries."
editUrl: false
sidebar:
  order: 6
---

<!-- Written by mix wardrik.docs from packages/wardrik_core/priv/v1. Edit it there, not here. -->

Every event is a CloudEvent: the envelope below, with the event's own data under `data`.

## The envelope

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `specversion` | `"1.0"` | yes |  |
| `id` | string | yes | A UUIDv7. |
| `source` | string | yes | The agent, or audit for a change people made. |
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

### `wardrik.activity.changed`

What the agent is doing changed, on the span of the event that changed it. Live: never stored.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `activity` | [activity](#activity) | yes |  |

### `wardrik.agent.cancelled`

Someone dropped the turn an agent was taking, and what was queued behind it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `resource` | string |  | The pattern someone cancelled every agent it covers by at once, where it was one of them; every agent's entry from that one change shares its trace. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.agent.cleared`

Someone emptied an agent's conversation.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.agent.defined`

Someone wrote an agent's definition, and the agent was started, or brought to it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.agent.forgotten`

Someone removed an agent, with everything it had.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `resource` | string |  | The pattern someone removed every agent it covers by at once, where it was one of them; every agent's entry from that one change shares its trace. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.agent.moved`

Someone started an agent again on another node.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `node` | string | yes | The node it moved to, by its Erlang name. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.agent.spawned`

Someone started an agent.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `node` | string | yes | The node, by its Erlang name. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

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

### `wardrik.agent.stopped`

An agent stopped, keeping its conversation: someone stopped it, or it went to sleep for having had nothing to do, until something wakes it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `node` | string |  | The node it stopped on, where it stopped itself. |
| `reason` | string |  | Why it stopped itself: idle, having had nothing to do for its idle timeout. Absent where someone stopped it. One of `idle`. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.agents.reloaded`

Someone had the files that declare agents read again.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `nodes` | array of string | yes | The nodes that read them. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.call.killed`

Someone stopped a tool call an agent was running; the model is answered with an error, and the turn goes on.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `call` | object | yes |  |
| `call.id` | string | yes | The tool call's id. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

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
| `note` | string |  |  |
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
| `cost` | [cost](#cost) or null |  | What the call cost, on a call the model answered; null where nobody prices the model, which is not the same as nothing. |
| `status` | string | yes | One of `ok`, `error`, `cancelled`. |
| `error` | [error](#error) |  |  |
| `duration_ms` | [duration_ms](#duration_ms) | yes |  |

### `wardrik.message.created`

Someone sent the agent a message, which it will answer; sender says who, where that is known.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | [message](#message) | yes |  |
| `sender` | [principal](#principal) |  |  |

### `wardrik.message.delta`

Text of an assistant message as it streams. Live: never stored.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | [message_ref](#message_ref) | yes |  |
| `delta` | string | yes |  |

### `wardrik.message.retrying`

The model failed to answer, and is asked again after a wait.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `message` | [message_ref](#message_ref) | yes |  |
| `attempt` | integer | yes | Which try after the first comes next. |
| `attempts` | integer | yes | How many tries after the first there may be. |
| `wait_ms` | [duration_ms](#duration_ms) | yes |  |
| `error` | [error](#error) | yes |  |

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

### `wardrik.room.bound`

Someone had an agent answer in a room of a channel.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `channel` | string | yes | The channel, by the name config.yaml gives it. |
| `room` | string | yes | The room, as the channel knows it, such as a Slack channel's id. |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `answers` | string | yes | When it answers: when mentioned, or to every message. One of `mentions`, `everything`. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.room.unbound`

Someone had the agent that answered in a room of a channel stop.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `channel` | string | yes | The channel, by the name config.yaml gives it. |
| `room` | string | yes | The room, as the channel knows it, such as a Slack channel's id. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

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

### `wardrik.secret.removed`

Someone took a secret out of the vault.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `secret` | object | yes |  |
| `secret.name` | string | yes |  |
| `owner` | string |  | The org, as acme, or the user, as acme/@jon, it is kept for; none where it is the deployment's. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.secret.stored`

Someone sealed a secret in the vault.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `secret` | object | yes |  |
| `secret.name` | string | yes |  |
| `owner` | string |  | The org, as acme, or the user, as acme/@jon, it is kept for; none where it is the deployment's. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.server.added`

Someone added an MCP server for an owner's agents.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `server` | object | yes |  |
| `server.name` | string | yes |  |
| `server.url` | string | yes |  |
| `owner` | string | yes | The org, as acme, or the user, as acme/@jon, whose agents it serves. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.server.removed`

Someone removed an MCP server an owner had added.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `server` | object | yes |  |
| `server.name` | string | yes |  |
| `owner` | string | yes | The org, as acme, or the user, as acme/@jon, whose agents it serves. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

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

### `wardrik.token.created`

Someone made an API token, which acts for whoever made it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `token` | object | yes |  |
| `token.id` | string | yes |  |
| `token.name` | string | yes |  |
| `principal` | [principal](#principal) | yes |  |
| `statements` | array of [statement](#statement) | yes | What it allows, on what; anything none states is denied. |
| `policy` | string |  | The policy every agent it defines runs under, ahead of the agent's own, by its name: what IAM calls a permissions boundary. Absent where it names none. |
| `expires` | string (date-time) |  | When it stops working. |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.token.revoked`

Someone revoked an API token.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `token` | object | yes |  |
| `token.id` | string | yes |  |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.tool_call.completed`

A tool call answered, or was answered from the ledger when replayed.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `tool` | [tool](#tool) | yes |  |
| `status` | string | yes | One of `ok`, `error`. |
| `error` | [error](#error) |  |  |
| `replayed` | boolean | yes |  |
| `served_by` | [served_by](#served_by) |  |  |
| `cost` | [cost](#cost) |  |  |

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

### `wardrik.trigger.fired`

A trigger came due.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `trigger` | object | yes |  |
| `trigger.name` | string | yes |  |
| `status` | string | yes | One of `asked`, `nothing_new`, `busy`, `no_agent`, `missed`, `failed`. |

### `wardrik.trigger.removed`

Someone removed one of an agent's triggers.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `trigger` | object | yes |  |
| `trigger.name` | string | yes |  |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

### `wardrik.trigger.set`

Someone set one of an agent's triggers.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `agent` | object | yes |  |
| `agent.id` | string | yes | The agent's ID. |
| `trigger` | object | yes |  |
| `trigger.name` | string | yes |  |
| `actor` | [principal](#principal) |  |  |
| `assumed_by` | [assumed_by](#assumed_by) |  |  |

## Shared types

The types events and bodies refer to.

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

### `cost`

What a call cost, the same figure a budget counts.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `micro_usd` | integer | yes | Whole micro-dollars: 1000000 is one US dollar. |
| `source` | string | yes | provider where the provider reported the figure, catalog where Wardrik priced the tokens at the model catalog's prices, tool where the tool reported it. One of `provider`, `catalog`, `tool`. |

### `principal`

Who did something, and how they were known.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `type` | string | yes | shell, ssh, terminal, channel, oauth, webhook, agent or user. A channel's id is the channel's name, its workspace and the id it knows them by there, as slack/T0123/U024BE7LH. |
| `id` | string | yes |  |
| `name` | string |  |  |

### `assumed_by`

Who acted for the actor, first to last, as an agent acting for the person who asked it something. Absent where the actor acted themselves.

No fields.

### `statement`

What a token allows, on what.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `actions` | array of string | yes | What it allows, as agent.ask or agents.list; agent.* is every action on one agent, and * every action. |
| `resources` | array of string | yes | What it allows them on, each a resource pattern, as IAM writes one: * matches anything, / included, and ? one character. acme/agent/* is acme's own agents, acme/@jon/* everything of jon's in acme, acme/* everything of acme's and its users', and * everything. |

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
| `name` | string |  | The tool the call is for, as the agent names it; none for a model's approval. |
| `labels` | array of string |  | The labels of what the run had read, which may be what asked for the call: outside for content nobody on the agent's side wrote. |

### `doing`

One thing an agent is doing, as the type of the event that set it, with what that event names of it.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `type` | string | yes | The type of the event that set it. One of `wardrik.run.started`, `wardrik.run.resumed`, `wardrik.run.interrupted`, `wardrik.message.started`, `wardrik.message.retrying`, `wardrik.step.started`, `wardrik.tool_call.started`, `wardrik.tool_call.completed`, `wardrik.tool_call.denied`. |
| `message` | [message_ref](#message_ref) |  |  |
| `attempt` | integer |  | Which try after the first comes next. |
| `attempts` | integer |  | How many tries after the first there may be. |
| `wait_ms` | [duration_ms](#duration_ms) |  |  |
| `step` | object |  |  |
| `step.name` | string | yes |  |
| `tool` | object |  |  |
| `tool.name` | string | yes |  |
| `tool.call` | object | yes |  |
| `tool.call.id` | string | yes |  |
| `interrupts` | array of [interrupt](#interrupt) |  |  |

### `activity`

What an agent is doing now.

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `doing` | array of [doing](#doing) | yes | Every tool call running, oldest first, or the one thing it is doing otherwise; none when it is idle. |
| `since` | string (date-time) | yes | When it began what it is doing. |
| `pending` | integer | yes | How many messages wait behind it. |
