---
title: Tools in your app
description: "Offer agents tools that run in your own process, with the TypeScript SDK, over a connection your app opens to the daemon."
sidebar:
  order: 3
  label: Overview
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

An agent whose file lists `workers/*` can now call `refund_order`. Its policy decides each call
first, so a refund waits for a person unless the policy allows it.

| Who | Does |
| --- | --- |
| Your app | holds the code and the keys, and runs each call |
| The daemon | decides each call by the agent's policy, and records it |
| A person | approves or denies the calls that wait |

The SDK is `@wardrik/sdk`, for Node 22.18 or later, Bun or Deno, with `zod` 4. It isn't on npm yet:
[Your first tool](/build/first-tool/#1-get-the-sdk) builds it from the repository.

## In this section

- [Your first tool, end to end](/build/first-tool/): a tool that posts to a status page, from an
  empty folder to a service, with an agent proposing posts and a person approving them.
- [Write tools](/build/write-tools/): arguments, results and errors; whose call it is; what a call
  cost; running a call twice.
- [Host your tools](/build/host-tools/): inside your app or on their own, on another machine or in a
  container, and through deploys.

Every method and option is in the [TypeScript SDK reference](/sdk/typescript/readme/).
