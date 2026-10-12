---
title: Tools in your app
description: Offer agents tools that run in your own process, with the TypeScript SDK, over a connection your app opens to the daemon.
sidebar:
  order: 5
---

A tool worker is your own app offering agents tools. The tools run in your process, with your code,
your database and your keys. The app opens a connection to the daemon and answers the calls agents
make over it, so the daemon needs no way to reach the app.

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

The SDK is `@wardrik/sdk`, for Node 22.18 or later, Bun or Deno, with `zod` 4 beside it. It is not
on npm yet: build it from `sdks/typescript` in the repository, with `npm ci && npm run build`.

## A token for the worker

`new Wardrik()` reads `WARDRIK_URL`, `http://127.0.0.1:4747` unless set, and `WARDRIK_TOKEN`. A
worker's token needs to `serve`, and its scope is the agents that may be offered its tools:

```sh
wardrik token create shop --scope acme/ --can serve
```

An agent file that names no `org` is in the deployment's, `default` unless `config.yaml` names
another, so a worker for such agents is made with `--scope default/`. See
[Tokens](/operate/security/#tokens).

Run as many workers under one token as you like: those offering a tool of the same name share its
calls. A tool is bound to the token that offers it. Where workers under a second token offer the same
name to the same agent, the agent keeps the tool of the token whose worker connected first, the
second is refused, and the daemon logs it. A call's events name the token that served it.

## Which agents have the tools

An agent is offered a worker's tools where its file lists `workers/*`, or `*`, and its key is under
the worker's scope:

```yaml
tools: [workers/*, linear/*]
```

The model sees each tool as `workers__refund_order`, and a policy names it as
`workers/refund_order`. A file cannot list one worker tool; a [policy](/concepts/policy/) decides
which may run.

Several workers may offer the same tool, as several copies of one app do, and each call goes to one
of them. A worker that goes away takes its tools with it, until it connects again.

## Writing a tool

`wardrik.tool` takes:

| Key | |
| --- | --- |
| `name` | the tool's name: letters, digits, `_` and `-`, up to 55. The daemon leaves out a tool whose name is not |
| `description` | what the model is told the tool does |
| `input` | a schema for its arguments, such as a `zod` object, sent to the model as JSON Schema |
| `readOnly` | whether it changes nothing. A tool that is not read-only is [gated](/concepts/policy/#gated-tools): a call to it asks a person unless a policy allows it by name |
| `idempotent` | whether running a call twice is safe; see below |
| `run` | the function, given the arguments, and `{ agent, run, idempotencyKey, signal, cost }` |

`run` answers with an object, which the model is given as the call's result, or a string, as text.
A thrown error is a failed call: the model is told its message, and the turn carries on.

A call may take up to 60 seconds. One that takes longer is cancelled, so `signal` aborts, and is left
in doubt; see below. `signal` aborts too when the agent stops the call: when it is killed, when its
turn runs out of time, or when the turn ends.

### Whose call it is

`agent` is the agent the call is made for, with its `key`, its `org`, its `user` where it works for
one, and its `name`. The daemon names it from the agent's key, which the worker's token was checked
against, never from what the model sent. So one worker can serve an agent for every customer, each
under a key of its own, and answer each with what is that customer's alone:

```ts
wardrik.tool({
  name: "list_orders",
  description: "List the customer's orders.",
  input: z.object({}),
  readOnly: true,
  run: (_args, { agent }) => db.orders.where({ customer: agent?.user }),
});
```

Here each customer's agent is `shop/@<customer id>/support`, and no argument the model writes can
reach another customer's orders. `run` is the run the call is part of, the id its events carry, so a
call can be matched with the turn it belongs to.

### What a call cost

A call to a paid API can say what it cost, in US dollars, with `cost`. The call's
`tool_call.completed` event carries it, and the agent's [budget](/concepts/policy/#budgets) counts
it. Said more than once, the amounts add up, and a call that throws after saying it is reported
failed at what it said, since a paid API may charge for a call that fails.

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

On the wire it is `_meta.costUsd` on the call's result.

### Running a call twice

Each call carries an idempotency key, the same each time the daemon runs it. Pass it on to anything
with an effect, as a payment provider's own idempotency key, so a call run twice does it once.

A call is run twice when the daemon cannot tell whether it finished: the node holding its agent was
lost while the call was running, or its worker went away or answered late. Where every worker
offering the tool marks it `idempotent` or `readOnly`, the call runs again under the same key, on a
worker connected then. Otherwise, or where it is in doubt again, it waits on a person to decide. The
model is never told it failed, so it never runs it again under a new key. See
[Durable runs](/concepts/durable-runs/#the-ledger).

## The connection

`work` opens a WebSocket to `/v1/workers` and answers calls over it, as an MCP server, until its
`signal` aborts:

```ts
const stop = new AbortController();
const working = wardrik.work({ signal: stop.signal });

process.on("SIGTERM", () => stop.abort());
await working;
```

It connects again after a drop, waiting longer each time, up to 30 seconds. A token the daemon
refuses throws a `WardrikError` instead, and revoking the token closes the connection.

## Outside content

A worker's answers are content from outside unless `config.yaml` says they are the deployment's
own:

```yaml
http:
  trusted_workers: true
```

Without it, a turn that has called a worker waits on a person before a gated tool's call runs. See
[Content from outside](/concepts/policy/#content-from-outside).

## Driving agents too

The same client drives agents over the HTTP API: it defines them, asks them things and follows what
they do. See [Use the HTTP API](/guides/http-api/). `examples/refund.ts` in the SDK runs a worker and
an agent that calls it together.
