---
title: Tools in your app
description: "Serve tools to agents from your own process with the TypeScript SDK, over an outbound connection to the daemon."
sidebar:
  order: 3
  label: Overview
---

A tool worker is a process in your app that serves tools to agents. The tools run in your process,
with your code, data and keys. Your app opens the connection, so the daemon needs no access to it.

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

- An agent with `workers/*` in its tools can call `refund_order`, if the worker's token has the
  `serve` verb.
- The agent's policy checks each call first. A refund needs approval unless the policy allows it.
- Requires Node 22.18+, Bun or Deno: `npm install @wardrik/sdk@0.1.0-rc.2 zod`.

## In this section

- [Your first tool](/build/first-tool/): from an empty directory to a service.
- [Write tools](/build/write-tools/): arguments, results, errors, cost, and retries.
- [Host your tools](/build/host-tools/): in your app or standalone, and across deploys.

Every method is in the [TypeScript SDK reference](/sdk/typescript/readme/).
