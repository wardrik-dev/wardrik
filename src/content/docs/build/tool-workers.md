---
title: Tools in your app
description: "Offer agents tools that run in your own process, with the TypeScript SDK, over a connection your app opens to the daemon."
sidebar:
  order: 3
---

A tool worker is your own app offering agents tools. The tools run in your process, with your code,
data and keys. Your app dials the daemon, so the daemon needs no way to reach it.

```ts
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";

const wardrik = new Wardrik({ name: "shop" });

wardrik.tool({
  name: "refund_order",
  description: "Refund an order in full.",
  input: z.object({ orderId: z.string() }),
  idempotent: true,
  run: ({ orderId }, { idempotencyKey }) =>
    stripe.refunds.create({ payment_intent: orderId }, { idempotencyKey }),
});

await wardrik.work();
```

The SDK is `@wardrik/sdk`, for Node 22.18 or later, Bun or Deno, with `zod` 4. It isn't on npm yet:
build it from `sdks/typescript` in the repository with `npm ci && npm run build`.

## 1. Make a token

A worker's token needs `serve`. Its scope is the agents that may use its tools:

```sh
wardrik token create shop --scope acme/ --can serve
WARDRIK_TOKEN=wardrik_... node shop.ts
```

`new Wardrik()` reads `WARDRIK_URL`, `http://127.0.0.1:4747` unless set, and `WARDRIK_TOKEN`. See
[Tokens](/run/tokens/).

## 2. Give agents the tools

An agent gets a worker's tools where its file lists `workers/*` and its key is under the token's
scope:

```yaml
tools: [workers/*, linear/*]
```

A policy names a tool as `workers/refund_order`. A tool that isn't `readOnly` is
[gated](/concepts/rules/#gated-tools): its calls wait on a person unless a policy allows them.

## 3. Write tools

`wardrik.tool` takes:

| Key | |
| --- | --- |
| `name` | letters, digits, `_` and `-`, up to 55 |
| `description` | what the model is told the tool does |
| `input` | a schema for its arguments, such as a `zod` object |
| `readOnly` | whether it changes nothing |
| `idempotent` | whether running a call twice is safe |
| `run` | the function, given the arguments and `{ agent, run, idempotencyKey, signal, cost }` |

`run` returns an object, or a string, as the call's result. A thrown error is a failed call: the
model is told its message, and the turn carries on.

### Whose call it is

`agent` names the agent the call is for, from its key, never from what the model sent. So one
worker can serve an agent per customer, each seeing only its own data:

```ts
wardrik.tool({
  name: "list_orders",
  description: "List the customer's orders.",
  input: z.object({}),
  readOnly: true,
  run: (_args, { agent }) => db.orders.where({ customer: agent?.user }),
});
```

Here each customer's agent is `shop/@<customer id>/support`.

### What a call cost

A call to a paid API can report its cost in US dollars, and the agent's
[budget](/concepts/budgets/) counts it:

```ts
wardrik.tool({
  name: "enrich_contact",
  description: "Look a contact up by email.",
  input: z.object({ email: z.string() }),
  readOnly: true,
  run: async ({ email }, { cost }) => {
    const found = await enrich.lookup(email);
    cost(0.01);
    return found;
  },
});
```

### Running a call twice

Each call carries an idempotency key, the same every time the daemon runs it. Pass it to anything
with an effect, such as a payment provider's own idempotency key, so a call run twice acts once.
Mark such a tool `idempotent`. See [Durable runs](/concepts/durable-runs/#the-ledger).

## 4. Keep it running

`work` holds a connection open and answers calls until its `signal` aborts:

```ts
const stop = new AbortController();
const working = wardrik.work({ signal: stop.signal });

process.on("SIGTERM", () => stop.abort());
await working;
```

The same client also drives agents; see [Use the HTTP API](/build/http-api/). `examples/refund.ts`
in the SDK runs a worker and an agent together.

## Details

### Scopes

- `acme/` is acme's own agents, none that work for a user. `--scope 'acme/*'` adds its users'
  agents, as an app's per-user agents need.
- An agent file that names no `org` is in the deployment's, `default` unless `config.yaml` says
  otherwise, so its worker is made with `--scope default/`.

### Several workers

- Workers under one token offering a tool of the same name share its calls; each call goes to one.
- A tool is bound to the token that offers it. Where a second token's workers offer the same name to
  the same agent, the first to connect keeps it, the second is refused, and the daemon logs it.
- A call's events name the token that served it.
- A worker that goes away takes its tools with it until it reconnects.
- `*` in an agent file includes `workers/*`. A file can't list one worker tool; a policy decides.
- The model sees each tool as `workers__refund_order`.

### Calls

- A tool with an invalid name is left out.
- `input` is sent to the model as JSON Schema.
- A call may take 60 seconds. Longer, it's cancelled, `signal` aborts, and the call is in doubt.
- `signal` also aborts when the agent stops the call: when it's killed, its turn times out, or the
  turn ends.
- `run` in the call context is the run's id, the one its events carry.
- `cost` said more than once adds up. A call that throws after saying it is reported failed at that
  cost. On the wire it's `_meta.costUsd`.

### Calls in doubt

A call is in doubt when the daemon can't tell whether it finished: the agent's node was lost during
it, or its worker went away or answered late. Where every worker offering the tool marks it
`idempotent` or `readOnly`, it runs again under the same key, on a worker connected then. Otherwise,
or where it's in doubt again, it waits on a person. The model is never told it failed, so it never
retries under a new key.

### The connection

- `work` opens a WebSocket to `/v1/workers` and answers calls as an MCP server.
- It reconnects after a drop, waiting longer each time, up to 30 seconds.
- A refused token throws a `WardrikError`. Revoking the token closes the connection.

### Outside content

A worker's answers are content from outside unless `config.yaml` says otherwise:

```yaml
http:
  trusted_workers: true
```

Without it, a turn that called a worker waits on a person before a gated call runs. See
[Content from outside](/concepts/outside-content/).
