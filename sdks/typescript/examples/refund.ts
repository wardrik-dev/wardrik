// An agent that refunds orders through a tool running in this process.
//
//   tars token create shop --scope acme/
//   TARS_TOKEN=tars_… TARS_MODEL=anthropic:claude-sonnet-5 node examples/refund.ts

import { z } from "zod";
import { Tars } from "../src/index.ts";

const tars = new Tars({ name: "shop" });
const stop = new AbortController();

tars.tool({
  name: "refund_order",
  description: "Refund an order in full.",
  input: z.object({ orderId: z.string() }),
  idempotent: true,
  run: ({ orderId }, { idempotencyKey }) => {
    console.log(`\n[worker] refunding ${orderId} under ${idempotencyKey}`);
    return { refund: `re_${orderId}`, status: "succeeded" };
  },
});

const working = tars.work({ signal: stop.signal });

const agent = await tars.agents.put("acme/_/refunds", {
  model: process.env.TARS_MODEL ?? "anthropic:claude-sonnet-5",
  instructions: "You refund orders when asked, with refund_order, and say what you did.",
  tools: ["workers/*"],
});

// Give the worker a moment to be listed before the first run.
await new Promise((resolve) => setTimeout(resolve, 500));

for await (const event of agent.ask("Please refund order o_42.")) {
  switch (event.type) {
    case "tars.message.delta":
      process.stdout.write(event.data.delta);
      break;
    case "tars.tool_call.started":
      console.log(`\n[agent] calling ${event.data.tool.name}`);
      break;
    case "tars.run.interrupted":
      for (const interrupt of event.data.interrupts) {
        console.log(`\n[agent] waiting on: ${interrupt.message}; approving`);
        await agent.approve(interrupt.id);
      }
      break;
    case "tars.run.completed":
    case "tars.run.failed":
    case "tars.run.cancelled":
      console.log(`\n[agent] ${event.type.slice("tars.run.".length)}`);
      break;
  }
}

stop.abort();
await working;
