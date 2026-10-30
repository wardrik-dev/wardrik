---
title: Pull the plug, then press stop
description: Kill -9 Wardrik mid-task and the agent finishes without doing a step twice. Stop it, and it stays stopped.
sidebar:
  order: 8
---

An agent sets up two new hires, one step at a time. We `kill -9` Wardrik halfway and start it
again. The agent finishes, with no step done twice. Then we stop the agent and kill Wardrik again.
The agent stays stopped.

## What it takes

- the `wardrik` command, [installed](/getting-started/install/), with a model provider's key;
- Node 22.18 or later.

## The files

### config.yaml

Run the demo apart from any daemon you have:

```sh
export XDG_CONFIG_HOME=~/plug/config XDG_DATA_HOME=~/plug/data XDG_STATE_HOME=~/plug/state
mkdir -p ~/plug/config/wardrik
cat > ~/plug/config/wardrik/config.yaml <<'EOF'
defaults:
  model: anthropic:claude-sonnet-5
http:
  port: 4848
  trusted_workers: true
EOF
```

`trusted_workers: true` treats the script's answers as your own, not
[content from outside](/concepts/outside-content/). Without it, every step after the first waits
for a person.

### onboarding.ts

The script plays IT. It offers three `idempotent` tools, keeps what each call did under its
idempotency key, and asks the agent to set up Ana and Ben:

```ts title="onboarding.ts"
import { setTimeout as sleep } from "node:timers/promises";
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";

const wardrik = new Wardrik({ name: "it" });

// 1. IT keeps what each call did under its idempotency key, as a provider's API does.
const done = new Map<string, Promise<string>>();
const changes: string[] = [];

function once(key: string | undefined, what: string, signal: AbortSignal): Promise<string> {
  const before = done.get(key ?? "");
  if (before) {
    console.log(`[it] ${what} again, same key: answering with the first result`);
    return before;
  }

  console.log(`[it] ${what}...`);
  const now = sleep(3000, undefined, { signal }).then(() => {
    changes.push(what);
    console.log(`[it] ${what}: done`);
    return `${what}: done`;
  });

  if (key) done.set(key, now);
  now.catch(() => {
    if (key) done.delete(key);
    console.log(`[it] ${what}: stopped before it happened`);
  });
  return now;
}

// 2. Three tools, each safe to run twice under the same key.
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

// 3. The agent, allowed to call them.
const agent = wardrik.agent("default/onboarding");
await agent.define({
  instructions:
    "You set new hires up. For each person in turn: their google, github and slack accounts, " +
    "then their laptop, then a short welcome email. One call at a time. Say when you're done.",
  tools: ["workers/*"],
  policy: { allow: ["workers/*"] },
});

// 4. Ask, and print what happens.
for await (const event of agent.stream("Ana and Ben start on Monday. Please set them both up.")) {
  if (event.type === "wardrik.agent.started") console.log(`[agent] started again on ${event.data.node}`);
  if (event.type === "wardrik.tool_call.completed" && event.data.replayed) console.log("[agent] answered from the log");
  if (event.type.startsWith("wardrik.run.") && event.type !== "wardrik.run.started") console.log(`[agent] ${event.type.slice(12)}`);
}

console.log(`[it] changes made: ${changes.length}\n  ${changes.join("\n  ")}`);
console.log("[it] still answering calls, until Ctrl-C");
await working;
```

Notice `idempotent: true`. A call cut off part way runs again only if its tool says it's safe to.

## Try it

### 1. Start Wardrik

```sh
export ANTHROPIC_API_KEY=sk-ant-...
wardrik start
wardrik token create it --resource 'default/agent/*' --role reader,messenger,definer,worker
```

The script needs `definer` to define the agent and `worker` to offer it tools. Copy the token's
secret, which starts `wrk_`.

### 2. Run the script

In another terminal, in a directory of its own:

```sh
npm install @wardrik/sdk@0.1.0-rc.1 zod
WARDRIK_URL=http://127.0.0.1:4848 WARDRIK_TOKEN=wrk_... node onboarding.ts
```

```
[it] google account for Ana...
[it] google account for Ana: done
[it] github account for Ana...
```

### 3. Pull the plug

While a step runs, kill Wardrik, then start it again:

```sh
kill -9 "$(wardrik pid)"
wardrik start
```

```
[it] laptop for Ana...
[it] laptop for Ana: stopped before it happened
[agent] started again on wardrik@localhost
[it] laptop for Ana...
[it] laptop for Ana: done
[it] welcome email to Ana...
...
[agent] completed
[it] changes made: 10
  google account for Ana
  github account for Ana
  slack account for Ana
  laptop for Ana
  ...
```

IT dropped the call when Wardrik went away. The agent carried on from its last step and made the
call again, under the same idempotency key. One laptop each.

### 4. Press stop

Remove the agent, run the script again, and stop the agent part way:

```sh
wardrik agent rm onboarding
WARDRIK_URL=http://127.0.0.1:4848 WARDRIK_TOKEN=wrk_... node onboarding.ts
```

```sh
wardrik agent cancel onboarding
```

```
[it] github account for Ana...
[it] github account for Ana: stopped before it happened
[agent] cancelled
[it] changes made: 1
  google account for Ana
[it] still answering calls, until Ctrl-C
```

### 5. Pull the plug again

```sh
kill -9 "$(wardrik pid)"
wardrik start
wardrik ls onboarding               # idle
```

No call arrives. The stop is in the store, so the agent comes back idle.

## What it shows

- **Durable agents.** Each step is written down before it runs, so a restarted Wardrik carries
  on from it. See [Durable runs](/concepts/durable-runs/).
- **No step twice.** A finished call is answered from the agent's log, never run again. See
  [Calls that may have run](/concepts/durable-runs/#calls-that-may-have-run).
- **Idempotency keys.** A call made again carries the same key. See
  [Running a call twice](/build/write-tools/#running-a-call-twice).
- **A stop that holds.** A cancelled turn stays cancelled across a crash.

## Details

### What a stop does

`wardrik agent cancel` ends the turn at once and drops the messages waiting behind it. A tool
worker sees its call's `signal` abort. A turn waiting on a person is abandoned. The SDK's
`agent.cancel()` does the same.

### Keeping it stopped

A cancel stops one turn. To keep an agent from starting another:

- remove its [triggers](/build/triggers/#changing-and-removing-triggers);
- revoke the [tokens](/run/tokens/) that message it or serve its tools;
- deny its tools in its [policy](/concepts/policy/);
- set a [budget](/concepts/budgets/) with `on_exhausted: deny`.

### How it resumes

A finished call is answered from the log, and its `wardrik.tool_call.completed` event says
`"replayed": true`. A call that began but never finished runs again only if its tool is
`idempotent`. Otherwise it waits for a person. Had the laptop order gone through, IT would have
answered the second call with the first result.

### Taking it further

- Kill Wardrik while the model answers: the steps before it are answered from the log.
- Drop `idempotent: true` from `order_laptop` and pull the plug: the cut-off call waits for a
  person.
- Keep the store in [Postgres](/run/storage/#in-postgres), and restart Wardrik on another machine.

### Cleaning up

Stop the script and Wardrik, remove `~/plug`, and open a new shell:

```sh
wardrik stop
rm -rf ~/plug
```
