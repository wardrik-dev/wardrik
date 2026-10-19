---
title: Quickstart
description: "Install Wardrik, ask its front door for an outcome, approve a call a policy holds, and give an agent a tool from your own app."
---

In ten minutes: install Wardrik, hand the front door some work, approve a call a policy holds, and
give an agent a tool from your own code.

## 1. Install

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik/releases/latest/download/install.sh | sh
wardrik init
```

`wardrik init` asks for a model provider and its key, starts the daemon, and writes the front door,
`~/.config/wardrik/agents/assistant.md`. [Install](/getting-started/install/) covers Docker and
scripted setup.

:::tip[rik is wardrik]
The install also adds `rik`, a short name for `wardrik`. Every command here works with either.
:::

## 2. Ask for an outcome

The front door is where you ask for what you want. Tell it an outcome:

```sh
wardrik ask assistant "Tell me when https://elixir-lang.org/atom.xml has a new post"
```

It explains its plan, then proposes the work as a call that waits for you:

```text
Waiting on a person for 1 call:
  ? agent_define  call_8d2ebbfe28aa4ee1a269dee2  agent_define is gated, so it a…
wardrik approve default/assistant, or deny, decides it.
```

Approve it, and the work runs on its own:

```sh
wardrik approve assistant call_8d2ebbfe28aa4ee1a269dee2
wardrik ls
```

`wardrik ls` lists the worker it defined; `wardrik triggers` says when it runs next. Tell it "check
every hour" or "stop", and it proposes the change. See [The front door](/build/front-door/).

## 3. See a policy at work

You can also write an agent yourself. It's a Markdown file: the frontmatter says what it may do,
the body is its prompt. This one's policy makes writing a note wait for a person:

```markdown title="~/.config/wardrik/agents/notes.md"
---
description: Keeps the team's notes.
tools: [files]
policy:
  ask:
    write_file: This writes a note.
---
You keep the team's notes in files. Say what you would write before you write it.
```

Load it and ask it something:

```sh
wardrik reload
wardrik ask notes "Start a MEMORY.md with today's date and what you are for."
```

The model calls `write_file`, and the policy holds it until you decide:

```sh
wardrik parked
```

```text
1 waiting:
  default/notes  call_5b1f…  write_file  This writes a note.
```

```sh
wardrik approve notes call_5b1f…
```

The call runs as the model wrote it. Or deny it with a reason, and the model is told why:
`wardrik deny notes CALL "Keep it to one line."` In [Slack](/channels/slack/), the same call shows
its arguments with **Approve** and **Deny**.

The agent names no `model`, so it uses the one `wardrik init` chose. See [Policy](/concepts/policy/)
for what else a policy can say.

## 4. Give it a tool from your app

A tool worker is your app offering agents tools. They run in your process, with your keys, and
your app dials the daemon, so nothing needs to reach it. Make a token for it:

```sh
wardrik token create shop --resource 'default/agent/*' --role worker
```

Then offer a tool with the TypeScript SDK, `@wardrik/sdk`. It isn't on npm yet; build it from
`sdks/typescript` in the repository.

```ts title="shop.ts"
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";

const wardrik = new Wardrik({ name: "shop" });

wardrik.tool({
  name: "order_status",
  description: "Say where an order is.",
  input: z.object({ orderId: z.string() }),
  readOnly: true,
  run: ({ orderId }) => ({ orderId, status: "shipped", carrier: "UPS" }),
});

await wardrik.work();
```

```sh
WARDRIK_TOKEN=wardrik_... node shop.ts
```

Add `workers/*` to the notes agent's `tools`, run `wardrik reload`, and ask "Where is order
1001?". It calls `order_status` in your process. A tool that isn't `readOnly` waits for a person, as
`write_file` did. See [Tools in your app](/build/tool-workers/).

## Next

- [Slack](/channels/slack/): put an agent in a channel, with approvals in the thread.
- [Examples](/examples/): agents to copy and run, from a morning brief to one that anyone may try to
  hijack.
- [Connect MCP servers](/build/mcp/): give agents the tools of the services you use.
- [Use the HTTP API](/build/http-api/): define and ask agents from any language.
- [Agent files](/reference/agent-files/): every key an agent file takes.
