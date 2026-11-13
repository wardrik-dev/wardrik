---
title: Tools in your app
description: "Register application tools with the TypeScript SDK. Execute approved calls in your own process."
sidebar:
  order: 3
  label: Overview
---

Register functions as agent tools with the TypeScript SDK. Your app executes the calls using
its own code, database, and API keys. This process is called a **tool worker**. It connects to
Wardrik over an outbound connection, so your app needs no inbound port.

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

- Add `workers/*` to the agent’s tools and grant the tool worker’s token permission to `serve` tools.
- The agent's policy checks each call first. A refund needs approval unless the policy allows it.
- Requires Node 22.18+, Bun or Deno: `npm install @wardrik/sdk@0.1.0-rc.7 zod`.

## In this section

- [Your first tool](/build/first-tool/): from an empty directory to a service.
- [Write tools](/build/write-tools/): arguments, results, errors, cost, and retries.
- [Host your tools](/build/host-tools/): in your app or standalone, and across deploys.

See all methods in the [TypeScript SDK reference](/sdk/typescript/readme/).
