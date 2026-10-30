---
title: Use the HTTP API
description: "Define an agent, ask it something, follow its answer and decide what it waits on, over HTTP or with the TypeScript SDK."
sidebar:
  order: 4
---

The daemon serves a JSON API on `127.0.0.1:4747`. This guide walks one agent through its life: a
token, a definition, a question, its answer, and a decision. The [HTTP API reference](/reference/http-api/)
lists every route.

## A token

Make a token with only what it needs, and send it as `authorization: Bearer`:

```sh
wardrik token create app --resource 'acme/agent/*' --role reader,messenger,approver,definer --policy careful
export TOKEN=wrk_...
curl -s -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents
```

The secret is printed once.

- `--resource` says what it reaches, and may be given again. `acme/agent/*` is acme's own agents,
  `acme/@jon/*` everything of jon's, and `acme/*` everything of acme and its users.
- `--role` says what it may do there.
- `--policy` holds every agent it defines to `careful`, ahead of the agent's own policy.

See [Tokens](/run/tokens/).

## Define an agent

`PUT` a definition at the agent's ID, written in full with its org:

```sh
curl -s -X PUT -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage \
  -d '{
    "description": "Watches the incident queue.",
    "instructions": "You watch the incident queue, and say what needs an engineer.",
    "model": "anthropic:claude-sonnet-5",
    "tools": ["linear/*"],
    "policy": {"ask": ["linear/create_*"]}
  }'
```

It starts the agent, and answers `200` with its snapshot. Putting it again replaces the definition,
and the running agent takes it from its next turn. A definition takes the keys of an
[agent file](/reference/agent-files/), with `instructions` as the system prompt.

Here `acme` is the deployment's org, `org: acme` in `config.yaml`. An org `config.yaml` doesn't
[declare](/run/orgs/#declare-an-org) is refused.

## Ask it something

`POST` a message. It answers `202` at once, and the agent answers in its own time:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage/messages \
  -d '{"id": "b7c1d0e2-...", "content": "What is on fire?"}'
# {"message": {"id": "b7c1d0e2-...", "cursor": "eyJhY21lL3RyaWFnZSI6NDF9"}}
```

`id` is optional. A message sent again with the same `id` is taken once, so a client can retry.

## Follow the answer

Stream the agent's events. The reply arrives as `wardrik.message.delta` events, then
`wardrik.message.completed` and `wardrik.run.completed`:

```sh
curl -N -H "authorization: Bearer $TOKEN" -H "accept: text/event-stream" \
  "http://127.0.0.1:4747/v1/agents/acme/triage/events?after=$CURSOR"
```

Notice `after`. It's the `cursor` the message answered with, where the agent's log stood, so
nothing of its turn is missed. A reconnecting client sends `Last-Event-ID` instead. Without
`accept: text/event-stream`, the same route answers one page of events. See
[The event stream](/concepts/events/#following-over-http).

## Decide what it waits on

A call that waits arrives as `wardrik.run.interrupted`. Each interrupt has an `id`, a `reason`, the
`message` a person is asked, and `labels` such as `["outside"]`. With a token holding `approver`:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/agents/acme/triage/decisions \
  -d '{"decisions": [{"id": "call_1", "decision": "approve", "note": "Label it for the next sprint."}]}'
```

- `"decision": "reject"` with a `"reason"` refuses it.
- One request can decide several calls.
- A note is read by the model beside the answer, and never changes the call. See
  [Approvals](/concepts/approvals/).
- `POST .../interrupts/{id}/approve` and `.../deny` decide one call.

## Connect accounts

A token that reaches a person's agents connects their accounts before any agent asks:

```sh
curl -s -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/connections?owner=acme/@jon"
# {"connections": [{"provider": "github", "connected": true}, {"provider": "linear", "connected": false}]}

curl -s -X POST -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/connections/linear?owner=acme/@jon"
# {"provider": "linear", "connected": false, "authorization": {"url": "https://…"}}
```

The account is held once the person authorizes at the link. See [Connect accounts](/build/accounts/).

## With the TypeScript SDK

The SDK does the same, and follows the stream for you:

```sh
npm install @wardrik/sdk@0.1.0-rc.1
```

```ts
import { Wardrik } from "@wardrik/sdk";

const wardrik = new Wardrik(); // WARDRIK_URL, else http://127.0.0.1:4747; WARDRIK_TOKEN
const agent = wardrik.agent("acme/triage");

await agent.define({
  model: "anthropic:claude-sonnet-5",
  instructions: "You watch the incident queue.",
  tools: ["linear/*"],
});

for await (const event of agent.stream("What is on fire?")) {
  if (event.type === "wardrik.message.delta") process.stdout.write(event.data.delta);

  if (event.type === "wardrik.run.interrupted") {
    for (const interrupt of event.data.interrupts) await agent.approve(interrupt.id);
  }
}
```

`stream` gives the events of the run that answers, until it completes, fails or is cancelled.
`agent.reply("...")` resolves once the run ends or waits, with its `text` or its `interrupts`. The
SDK also runs tools in your app; see [Tools in your app](/build/tool-workers/).

## Details

### Definitions

- A definition names tools and policies the daemon ships or configures, never a module.
- It shares only the trees whose owners' agents its token reaches, and can't trust outside content.
- `notify` works as in an agent file; see [Send notices](/build/notices/).
- `GET /v1/agents/acme/triage` answers the snapshot: its status and node, what it's doing, what it
  waits on, and the `cursor` it was taken at. `GET .../definition` answers the definition.

### Accounts and interrupts

- An interrupt with the reason `authorization` waits for a person to connect an account.
  `GET .../interrupts/{id}/authorization` answers where, as `{"url": ..., "code": ...}`.
- `connected` says whether the owner holds it, which is what a call of their agents would use. An
  org's account is not its people's.
- `owner` names whose accounts: a person's, `acme/@jon`, or an org's, `acme`.
- Listing needs the `reader` role. Connecting and forgetting (`DELETE /v1/connections/linear`) need
  `definer`.

### Stop, clear and remove

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents/acme/triage/cancel
curl -s -X DELETE -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents/acme/triage/conversation
curl -s -X DELETE -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/agents/acme/triage
```

- `cancel` stops the running turn, drops the messages behind it, and abandons one waiting on a
  person. An agent taking no turn is left as it is. It answers `202`.
- `DELETE .../conversation` empties the conversation and its
  [outside label](/concepts/outside-content/), and answers the snapshot. It answers `409` while a
  turn runs or waits.
- `DELETE` stops the agent and removes its conversation, definition and triggers, answering `204`.
  An agent an agent file declares answers `409`: remove the file and reload.
- `POST /v1/agents/cancel?resources=acme/agent/*` and `DELETE /v1/agents?resources=acme/agent/*` act
  on every agent the pattern covers.
- `GET /v1/agents?resources=acme/agent/*` lists agents. `GET /v1/interrupts` lists the calls they
  wait on.
- `POST .../stop` puts an agent to sleep with its conversation. `POST .../spawn` starts it again
  from its definition.
- `POST .../move` with `{"node": "wardrik@box2"}` starts it on another node. It takes a token with
  `owner` on `*` or `deployment`.
- Triggers are set and removed at `/triggers/{name}`; see
  [Trigger an agent](/build/triggers/#over-http). Webhooks reach `POST /v1/hooks/{agent}/{name}`
  with no token; see [Receiving a webhook](/build/triggers/#receiving-a-webhook).

### The deployment

A token made with `wardrik token create NAME --resource '*' --role owner` also reaches the deployment:

```sh
curl -s -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/deployment/nodes
curl -s -X POST -H "authorization: Bearer $TOKEN" http://127.0.0.1:4747/v1/deployment/reload
curl -s -H "authorization: Bearer $TOKEN" "http://127.0.0.1:4747/v1/deployment/audit?starting_after=120"
```

- `nodes` counts the agents running on each node, and those asleep.
- `reload` reads the agent and policy files again.
- `audit` pages what people changed, as `wardrik audit` does.

`/v1/tokens` makes, lists and revokes tokens:

```sh
curl -s -X POST -H "authorization: Bearer $TOKEN" -H "content-type: application/json" \
  http://127.0.0.1:4747/v1/tokens \
  -d '{"name": "ci", "resources": ["acme/agent/*"], "roles": ["reader", "messenger"], "expires_in": 2592000}'
```

It answers `201` with the token and its `secret`, given this once. The token acts for whoever made
it, and is no wider than they are. It lasts 90 days unless `expires_in` says otherwise.

### Errors

An error answers with its status and `{"error": {"type": ..., "message": ...}}`:

| Status | `type` | |
| --- | --- | --- |
| 400 | `invalid_request` | the request doesn't read |
| 401 | `unauthorized` | no token, or one that doesn't work or has expired |
| 403 | `forbidden` | the token reaches the agent, and doesn't allow this |
| 404 | `not_found` | no such agent, or one the token doesn't reach |
| 409 | `conflict` | the agent isn't waiting on that call, or is busy, or a file declares it |
| 500 | `internal` | something went wrong in Wardrik |
| 501 | `not_supported` | a key or feature this deployment doesn't support |
| 503 | `unavailable` | the store can't answer now, as in a cluster without a quorum |

Every answer has a `request-id` header, the caller's own where it sent one.

### SDK extras

- `wardrik.connections` lists, connects and forgets accounts, with `{owner: "acme"}` for the org's.
- `wardrik.mcpServers` lists, adds and removes the MCP servers a person or org adds for their
  agents.
- `wardrik.deployment` lists nodes and reloads. `wardrik.audit` pages the audit.
- A refused request throws a `WardrikError` with its `status`, `type` and `requestId`.
