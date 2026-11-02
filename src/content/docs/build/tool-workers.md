---
title: Tools in your app
description: "Offer agents tools that run in your own process, with the TypeScript SDK, over a connection your app opens to the daemon."
sidebar:
  order: 3
  label: Overview
---

A tool worker is your app offering agents tools. The tools run in your process, with your code,
data and keys. Your app connects to the daemon, so the daemon never reaches into it.

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

- An agent with `workers/*` in its tools can call `refund_order`, if the worker's token may
  `serve` it.
- The agent's policy decides each call first. A refund waits for a person unless the policy allows
  it.
- Needs Node 22.18 or later, Bun or Deno: `npm install @wardrik/sdk@0.1.0-rc.2 zod`.

## In this section

- [Your first tool](/build/first-tool/): from an empty folder to a service.
- [Write tools](/build/write-tools/): arguments, results, errors, cost, and running a call twice.
- [Host your tools](/build/host-tools/): inside your app or on their own, and through deploys.

Every method is in the [TypeScript SDK reference](/sdk/typescript/readme/).
