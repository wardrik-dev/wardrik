// Two new hires set up for their first day, one step at a time and each
// taking a few seconds, so the node the agent runs on can be killed part way,
// or the agent stopped. IT keeps what each call did under its idempotency key,
// as a provider's API does, so a step run again after a lost node happens once.
// The worker answers calls until Ctrl-C, so a stopped agent can be seen to
// stay stopped.
//
// Each tool changes something, so each is gated, and the agent's policy
// allows them by name. Run it against a daemon whose config.yaml says
// `http: {trusted_workers: true}`, or each call after the first waits on a
// person, since a worker's answer is otherwise content from outside.
//
//   wardrik token create it --scope default/ --role owner
//   WARDRIK_TOKEN=wardrik_… node examples/onboarding.ts

import { setTimeout as sleep } from "node:timers/promises";
import { z } from "zod";
import { Wardrik } from "../src/index.ts";

const wardrik = new Wardrik({ name: "it" });
const stop = new AbortController();

// What each call did, under its idempotency key, while it runs and after.
const done = new Map<string, Promise<string>>();
const changes: string[] = [];
let calls = 0;

async function change(what: string, signal: AbortSignal): Promise<string> {
  console.log(`\n[it] ${what}...`);
  await sleep(3000, undefined, { signal });
  changes.push(what);
  console.log(`[it] ${what}: done`);
  return `${what}: done`;
}

// A step stopped before it happened is forgotten, so it can happen later.
function once(key: string | undefined, what: string, signal: AbortSignal): Promise<string> {
  calls++;
  const id = key ?? crypto.randomUUID();
  const before = done.get(id);

  if (before) {
    console.log(`\n[it] ${what} again, under the same key: answering with what it did`);
    return before;
  }

  const now = change(what, signal);
  done.set(id, now);
  now.catch(() => {
    done.delete(id);
    console.log(`[it] ${what}: stopped before it happened`);
  });
  return now;
}

wardrik.tool({
  name: "create_account",
  description: "Create a new hire's account in one system.",
  input: z.object({ person: z.string(), system: z.enum(["google", "github", "slack"]) }),
  idempotent: true,
  run: ({ person, system }, { idempotencyKey, signal }) =>
    once(idempotencyKey, `${system} account for ${person}`, signal),
});

wardrik.tool({
  name: "order_laptop",
  description: "Order a new hire's laptop, delivered before their first day.",
  input: z.object({ person: z.string() }),
  idempotent: true,
  run: ({ person }, { idempotencyKey, signal }) =>
    once(idempotencyKey, `laptop for ${person}`, signal),
});

wardrik.tool({
  name: "send_welcome",
  description: "Email a new hire their welcome, with the plan for their first day.",
  input: z.object({ person: z.string(), text: z.string() }),
  idempotent: true,
  run: ({ person }, { idempotencyKey, signal }) =>
    once(idempotencyKey, `welcome email to ${person}`, signal),
});

const working = wardrik.work({ signal: stop.signal });

const agent = await wardrik.agents.put("default/onboarding", {
  model: process.env.WARDRIK_MODEL ?? "anthropic:claude-sonnet-5",
  instructions:
    "You set new hires up for their first day. For each person in turn: their google account, " +
    "then github and slack, then their laptop, then a short welcome email with the plan for " +
    "their first day. One call at a time, in that order. When everyone is set up, say so.",
  tools: ["workers/*"],
  policy: { allow: ["workers/*"] },
});

// Give the worker a moment to be listed before the first run.
await sleep(500);

const listed = await wardrik.agents.list();
console.log(`[agent] runs on ${listed.find((one) => one.id === agent.key)?.node}`);

for await (const event of agent.ask("Ana and Ben start on Monday. Please set them both up.")) {
  switch (event.type) {
    case "wardrik.agent.started":
      console.log(`\n[agent] carries on on ${event.data.node}`);
      break;
    case "wardrik.tool_call.completed":
      if (event.data.replayed) console.log(`[agent] ${event.data.tool.call.id} answered from the ledger`);
      break;
    case "wardrik.message.delta":
      process.stdout.write(event.data.delta);
      break;
    case "wardrik.run.completed":
    case "wardrik.run.failed":
    case "wardrik.run.cancelled":
      console.log(`\n[agent] ${event.type.slice("wardrik.run.".length)}`);
      break;
  }
}

const report = () =>
  console.log(`[it] ${changes.length} changes made, for ${calls} calls:\n  ${changes.join("\n  ")}`);

report();
console.log("[it] still answering calls, until Ctrl-C");

process.on("SIGINT", () => stop.abort());
await working;
report();
