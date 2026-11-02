---
title: Use the HTTP API
description: "Create an agent, send it a message, stream its reply and approve its tool calls, over HTTP or with the TypeScript SDK."
sidebar:
  order: 4
---

The daemon serves a JSON API on `127.0.0.1:4747`. The [HTTP API reference](/reference/http-api/)
lists every route.

## A token

```sh
wardrik token create jon-laptop --subject user:acme/@jon
export TOKEN=wdk_...
```

- The secret is printed once. Send it as `authorization: Bearer`.
- `acme/@jon` is the user `@jon` in the org `acme`. A user has full access to agents they own.
- Other access needs a binding in `config.yaml`. See [Orgs, roles and tokens](/run/orgs/).

## Create an agent

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/owners/acme%2F%40jon/agents \
  -d '{
    "name": "triage",
    "model": "anthropic:claude-sonnet-5",
    "instructions": "You watch the incident queue, and say what needs an engineer.",
    "tools": ["linear/*"],
    "policy": {"ask": ["linear/create_*"]}
  }'
# {"id": "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN", "name": "triage", "org": "acme", "owner": "acme/@jon"}

export AGENT=agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN
```

- The daemon generates the agent ID. Every other route takes it.
- `{owner}` is one URL-encoded segment: `acme` for the org, `acme%2F%40jon` for the user.
- A definition has the keys of an [agent file](/reference/agent-files/).
- `PUT /v1/agents/$AGENT` replaces the definition, starting with the next turn.
- `GET /v1/owners/acme/agents?name=triage` looks up an agent by name.

## Send a message

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/$AGENT/messages \
  -d '{"content": "What is on fire?"}'
# {"message": {"id": "msg_01…", "cursor": "W1siYWd0XzAxSkY4…"}}
```

It returns `202` immediately. To use a separate conversation, post to
`/v1/agents/$AGENT/conversations/C1/messages`.

## Stream the reply

```sh
curl -N -H "authorization: Bearer $TOKEN" -H "accept: text/event-stream" \
  "http://127.0.0.1:4747/v1/agents/$AGENT/events?after=$CURSOR"
```

- Pass the message's `cursor` as `after` to receive every event of its turn.
- The reply arrives as `wardrik.message.delta` events, then `wardrik.message.completed` and
  `wardrik.run.completed`.
- Without `accept: text/event-stream`, it returns one page of JSON. See [Events](/concepts/events/).

## Approve tool calls

A call that needs approval emits `wardrik.run.interrupted`, with an `id` for each call:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/$AGENT/decisions \
  -d '{"decisions": [{"id": "call_1", "decision": "approve", "note": "Label it for the next sprint."}]}'
```

- `"decision": "reject"` with a `"reason"` denies it.
- `POST .../interrupts/{id}/approve` and `.../deny` act on one call.
- The model receives the `note` with the result. See [Approvals](/concepts/approvals/).

## With the TypeScript SDK

```sh
npm install @wardrik/sdk@0.1.0-rc.2 zod
```

```ts
import { Wardrik } from "@wardrik/sdk";

const wardrik = new Wardrik(); // WARDRIK_URL, else http://127.0.0.1:4747; WARDRIK_TOKEN
const agent = wardrik.agent(process.env.AGENT!);

for await (const event of agent.stream("What is on fire?")) {
  if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);

  if (event.type === "wardrik.run.interrupted") {
    for (const interrupt of event.data.interrupts) await agent.approve(interrupt.id);
  }
}
```

- `agent.reply("...")` resolves when the turn ends or pauses for approval.
- The SDK covers Wardrik's routes. For the daemon-only routes (`/v1/owners`, `/v1/connections`,
  `/v1/tokens`), use `fetch`.
- It also serves tools from your app. See [Tools in your app](/build/tool-workers/).

Errors return `{"error": {"type": ..., "message": ...}}`. Cancel, stop, remove, triggers and every
other route are in the [HTTP API reference](/reference/http-api/).
