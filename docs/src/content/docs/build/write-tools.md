---
title: Write tools
description: "Define a tool's arguments, result and errors, answer each agent with its own data, report cost, and make a call safe to run twice."
sidebar:
  order: 3.2
---

A tool is a name, a description, a schema for its arguments, and a function. The function is your
own code: call your services, query your database, use your keys.

```ts
import { orders } from "./orders.ts"; // your app's own code

wardrik.tool({
  name: "find_order",
  description: "The order a Stripe payment intent paid for: items, address, dates.",
  input: z.object({ payment_intent: z.string() }),
  readOnly: true,
  run: ({ payment_intent }) => orders.byPaymentIntent(payment_intent),
});
```

`wardrik.tool` takes:

| Key | |
| --- | --- |
| `name` | letters, digits, `_` and `-`, up to 55 |
| `description` | what the model is told the tool does |
| `input` | a schema for its arguments, such as a `zod` object |
| `readOnly` | whether it changes nothing |
| `idempotent` | whether running a call twice is safe |
| `run` | the function, given the arguments and `{ agent, run, idempotencyKey, signal, cost }` |

## Give agents the tools

An agent gets a worker's tools where its file lists `workers/*` and its key is under the worker
token's scope:

```yaml
tools: [workers/*, linear/*]
```

A policy names a tool as `workers/find_order`. A tool that isn't `readOnly` is
[gated](/concepts/rules/#gated-tools): its calls wait on a person unless a policy allows them.

## Results and errors

`run` returns an object, or a string, as the call's result. Return what the model needs, not the
whole record: it reads every word.

A thrown error is a failed call. The model is told its message, and the turn carries on, so say
what went wrong in words it can act on:

```ts
run: async ({ order_id }) => {
  const order = await orders.find(order_id);
  if (!order) throw new Error(`No order ${order_id}. Order ids look like ord_1234.`);
  return { id: order.id, status: order.status, items: order.items.length };
},
```

`input` reaches the model as JSON Schema. A `.describe()` on a field tells it what goes there.

## Whose call it is

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

## What a call cost

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

## Running a call twice

Each call carries an idempotency key, the same every time the daemon runs it. Pass it to anything
with an effect, such as a payment provider's own idempotency key, so a call run twice acts once.
Mark such a tool `idempotent`.

```ts
wardrik.tool({
  name: "refund_order",
  description: "Refund an order in full.",
  input: z.object({ orderId: z.string() }),
  idempotent: true,
  run: ({ orderId }, { idempotencyKey }) =>
    stripe.refunds.create({ payment_intent: orderId }, { idempotencyKey }),
});
```

An API that takes no key can be given one of your own. Keep what each key did, and answer with
that when the key comes again:

```ts
run: async (incident, { idempotencyKey }) => {
  const done = await db.posts.find(idempotencyKey);
  if (done) return done;

  const posted = await statuspage.open(incident);
  await db.posts.insert(idempotencyKey, posted);
  return posted;
},
```

A crash between posting and saving still posts twice. Mark the tool `idempotent` only if that's
acceptable. Left unmarked, a call the daemon can't account for waits for a person. See
[Calls in doubt](/build/host-tools/#calls-in-doubt).

## Stop when asked

`signal` aborts when the agent stops the call: when it's killed, its turn times out, or the turn
ends. Pass it to `fetch` and anything else that takes one.

## Details

- A tool with an invalid name is left out.
- The model sees each tool as `workers__find_order`.
- A call may take 60 seconds. Longer, it's cancelled, `signal` aborts, and the call is in doubt.
- `run` in the call context is the run's id, the one its events carry.
- `cost` said more than once adds up. A call that throws after saying it is reported failed at that
  cost. On the wire it's `_meta.costUsd`.
