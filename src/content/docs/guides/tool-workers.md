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
| `idempotent`, `readOnly` | whether running a call twice is safe; see below |
| `run` | the function, given the arguments, and `{ idempotencyKey, signal }` |

`run` answers with an object, which the model is given as the call's result, or a string, as text.
A thrown error is a failed call: the model is told its message, and the turn carries on.

A call may take up to 60 seconds. One that takes longer is answered as timed out, the model is told
it may already have done what it does, and `signal` aborts.

### Running a call twice

Each call carries an idempotency key, the same each time the daemon runs it. Pass it on to anything
with an effect, as a payment provider's own idempotency key, so a call run twice does it once.

A call is run twice when the node holding its agent was lost while the call was running: the daemon
cannot tell whether it finished. Where every worker offering the tool marks it `idempotent` or
`readOnly`, the call runs again under the same key. Otherwise it waits on a person to decide. See
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
