---
title: Test crash recovery and cancellation
description: Restart Wardrik during a task to test saved results, idempotent retries, and persistent cancellation.
sidebar:
  order: 8
---

Simulate onboarding two new hires, then kill and restart Wardrik during a tool call. Completed
calls replay from the log; interrupted calls retry with the same idempotency key. Cancel a turn
and restart again to verify that cancellation is saved.

The demo tools simulate account creation, laptop orders, and email. They do not call external services.

Requires Node 22.18+ and `jq`.

## The files

Isolate the demo from any existing daemon:

```sh
export XDG_CONFIG_HOME=~/plug/config XDG_DATA_HOME=~/plug/data XDG_STATE_HOME=~/plug/state
mkdir -p ~/plug/config/wardrik/agents
```

```yaml title="~/plug/config/wardrik/config.yaml"
defaults:
  model: anthropic:claude-sonnet-5
http:
  port: 4848
  trusted_workers: true
roles:
  it:
    rules: [{verbs: [read, events, ask, cancel, serve], kinds: [agent], names: [onboarding]}]
bindings:
  - {org: default, role: it, subjects: [user:default/@it]}
```

- `trusted_workers: true` marks the script's results as trusted, so later calls don't need approval.
- The `it` role allows the script to message the agent, stream its events and serve its tools.

```markdown title="~/plug/config/wardrik/agents/onboarding.md"
---
tools: [workers/*]
policy: {allow: [workers/*]}
---
You set new hires up. For each person in turn: their google, github and slack accounts, then their
laptop, then a short welcome email. One call at a time. Say when you're done.
```

```ts title="onboarding.ts"
import { setTimeout as sleep } from "node:timers/promises";
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";

const wardrik = new Wardrik({ name: "it" });

// IT keeps what each call did under its idempotency key, as a payment API does.
const done = new Map<string, Promise<string>>();

function once(key: string | undefined, what: string, signal: AbortSignal): Promise<string> {
  const before = key && done.get(key);
  if (before) return before;

  console.log(`[it] ${what}...`);
  const now = sleep(3000, undefined, { signal }).then(() => {
    console.log(`[it] ${what}: done`);
    return `${what}: done`;
  });
  if (key) done.set(key, now);
  now.catch(() => key && done.delete(key));
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
  description: "Order a new hire's laptop.",
  input: z.object({ person: z.string() }),
  idempotent: true,
  run: ({ person }, { idempotencyKey, signal }) => once(idempotencyKey, `laptop for ${person}`, signal),
});

wardrik.tool({
  name: "send_welcome",
  description: "Email a new hire their welcome.",
  input: z.object({ person: z.string(), text: z.string() }),
  idempotent: true,
  run: ({ person }, { idempotencyKey, signal }) =>
    once(idempotencyKey, `welcome email to ${person}`, signal),
});

const working = wardrik.work();
const agent = wardrik.agent(process.env.AGENT!);

for await (const event of agent.stream("Ana and Ben start on Monday. Please set them both up.")) {
  if (event.type === "wardrik.agent.started") console.log(`[agent] started again on ${event.data.node}`);
  if (event.type === "wardrik.tool_call.completed" && event.data.replayed) console.log("[agent] answered from its log");
  if (event.type === "wardrik.run.completed" || event.type === "wardrik.run.cancelled") console.log(`[agent] ${event.type}`);
}

await working;
```

`idempotent: true` allows an interrupted call to be retried with the same key.

## Try it

```sh
export ANTHROPIC_API_KEY=sk-ant-...
wardrik start
wardrik token create it --subject user:default/@it --expires 1d     # copy the secret
wardrik agent show onboarding --json | jq -r .agent.agent  # the agent's ID
```

In another terminal, in a new directory:

```sh
npm install @wardrik/sdk@0.1.0-rc.6 zod
WARDRIK_URL=http://127.0.0.1:4848 WARDRIK_TOKEN=... AGENT=agt_... node onboarding.ts
```

While a call is running, kill the daemon:

```sh
kill -9 "$(wardrik pid)"
wardrik start
```

```
[it] laptop for Ana...
[agent] started again on wardrik@localhost
[it] laptop for Ana...
[it] laptop for Ana: done
...
[agent] wardrik.run.completed
```

The tool worker uses idempotency keys to avoid duplicate effects. Its deduplication map is kept
in memory for this demo; a production tool needs durable storage or an API with idempotency support.

Clear the agent’s history, run the script again, and cancel the turn midway:

```sh
wardrik agent clear onboarding
wardrik agent cancel onboarding      # while a step runs
kill -9 "$(wardrik pid)"
wardrik start
wardrik ls onboarding                # idle
```

No calls run. The cancellation was persisted, so the agent restarts idle.

## How it works

- Each round is persisted before it runs, so a restarted Wardrik resumes from it. See
  [Durable runs](/concepts/agents/#durable-runs).
- Calls with saved results replay from the log (`"replayed": true`) instead of executing again.
- A retried call has the same idempotency key.
- Remove `idempotent: true` and kill the daemon. The interrupted call needs approval instead.
- A cancelled turn stays cancelled across a crash.

Clean up with `wardrik stop && rm -rf ~/plug`, then open a new shell.
