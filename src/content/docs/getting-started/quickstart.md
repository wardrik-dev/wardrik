---
title: Quickstart
description: "Install Wardrik, ask its front door for an outcome, approve a call a policy holds, and give an agent a tool from your own app."
---

In ten minutes: install Wardrik, hand the front door some work, approve a call a policy holds, and
give an agent a tool from your own code.

## 1. Install

```sh
curl -fsSL https://github.com/wardrik-dev/wardrik_daemon/releases/download/v0.1.0-rc.1/install.sh | WARDRIK_VERSION=0.1.0-rc.1 sh
wardrik init
```

`wardrik init` asks for your model provider and its key, writes `config.yaml`, the env file and
the front door, `~/.config/wardrik/agents/assistant.md`, starts the daemon, seals the key in the
vault and asks the front door one question. [Install](/getting-started/install/) covers Docker,
systemd and other models.

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
  ? agent_define  call_8d2ebbfe28aa4ee1a269dee2  agent_define needs your approval.
Decide with: wardrik approval approve default/assistant ID, or wardrik approval deny default/assistant ID
```

Approve it, and the work runs on its own:

```sh
wardrik approval approve assistant call_8d2ebbfe28aa4ee1a269dee2
wardrik ls
```

`wardrik ls` lists the worker it defined. `wardrik trigger ls NAME` says when that worker runs
next. Tell the front door "check every hour" or "stop", and it proposes the change. See
[The front door](/build/front-door/).

## 3. See a policy at work

You can also write an agent yourself. It's a Markdown file: the frontmatter says what it may do,
and the body is its prompt. This one's policy makes writing a note wait for a person:

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
wardrik approval ls
```

```text
AGENT          CALL       TOOL        WHY
default/notes  call_5b1f  write_file  This writes a note.
```

```sh
wardrik approval approve notes call_5b1f
```

The call runs as the model wrote it. Or deny it with a reason, and the model is told why:

```sh
wardrik approval deny notes call_5b1f --reason "Keep it to one line."
```

In [Slack](/channels/slack/), the same call shows its arguments with **Approve** and **Deny**.

Notice the agent names no `model`. It uses the one in `config.yaml`'s `defaults`. See
[Policy](/concepts/policy/) for what else a policy can say.

## 4. Give it a tool from your app

A tool worker is your app offering agents tools. The tools run in your process, with your keys.
Your app dials the daemon, so nothing needs to reach your app.

1. Make a token for it:

   ```sh
   wardrik token create shop --resource 'default/agent/*' --role worker
   ```

2. Install the TypeScript SDK:

   ```sh
   npm install @wardrik/sdk@0.1.0-rc.1 zod
   ```

3. Offer a tool:

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

4. Run it with the token's secret:

   ```sh
   WARDRIK_TOKEN=wardrik_... node shop.ts
   ```

5. Add `workers/*` to the notes agent's `tools`, run `wardrik reload`, and ask "Where is order
   1001?".

The agent calls `workers__order_status`, which runs in your process. A tool that isn't `readOnly`
waits for a person, as `write_file` did. See [Tools in your app](/build/tool-workers/).

## Next

- [Slack](/channels/slack/): put an agent in a channel, with approvals in the thread.
- [Examples](/examples/): agents to copy and run, from a morning brief to one that anyone may try to
  hijack.
- [Connect MCP servers](/build/mcp/): give agents the tools of the services you use.
- [Use the HTTP API](/build/http-api/): define and ask agents from any language.
- [Agent files](/reference/agent-files/): every key an agent file takes.
