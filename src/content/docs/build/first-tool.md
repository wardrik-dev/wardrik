---
title: Your first tool, end to end
description: "Build a tool that posts to Statuspage, let an agent propose a post, approve it, then run the tool as a service."
sidebar:
  order: 3.1
---

You'll build `post_status`, the tool the [incident responder](/examples/team/incident-responder/)
uses to post on a public status page. It runs in a small Node app of your own. At the end, an agent
proposes a post, you approve it, and your app posts it.

You need the daemon [installed](/getting-started/install/), Node 22.18 or later, and a
[Statuspage](https://developer.statuspage.io/) page ID and API key.

## 1. Start an app

```sh
mkdir statuspage && cd statuspage
npm init -y && npm pkg set type=module
npm install @wardrik/sdk@0.1.0-rc.1 zod
```

## 2. Write the tool

```ts title="statuspage.ts"
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";

const page = process.env.STATUSPAGE_PAGE_ID;
const key = process.env.STATUSPAGE_API_KEY;

const wardrik = new Wardrik({ name: "statuspage" });

wardrik.tool({
  name: "post_status",
  description: "Open an incident on the public status page, with its first update.",
  input: z.object({
    name: z.string().describe("The incident's title, as customers see it"),
    status: z.enum(["investigating", "identified", "monitoring", "resolved"]),
    body: z.string().describe("The first update, in plain words"),
  }),
  run: async (incident, { signal }) => {
    const url = `https://api.statuspage.io/v1/pages/${page}/incidents`;
    const response = await fetch(url, {
      method: "POST",
      headers: { authorization: `OAuth ${key}`, "content-type": "application/json" },
      body: JSON.stringify({ incident }),
      signal,
    });
    if (!response.ok) {
      throw new Error(`Statuspage answered ${response.status}: ${await response.text()}`);
    }

    const { id, shortlink } = await response.json();
    return { id, shortlink };
  },
});

const stop = new AbortController();
process.on("SIGTERM", () => stop.abort());
process.on("SIGINT", () => stop.abort());

await wardrik.work({ signal: stop.signal });
```

- It isn't `readOnly`, so every call [waits for a person](/concepts/rules/#gated-tools) unless a
  policy allows it.
- A thrown error is a failed call. The model is told the message, and can fix its arguments.
- It returns only the incident's id and link. The model doesn't need the rest.
- `signal` aborts when the call is stopped, which ends the request.

## 3. Connect it

Make a token that may serve tools to the deployment's agents:

```sh
wardrik token create statuspage --resource 'default/agent/*' --role worker
```

`default` is the org of every agent file, unless `config.yaml` names another `org`. The secret is
printed once.

Run the app with it:

```sh
export STATUSPAGE_PAGE_ID=... STATUSPAGE_API_KEY=...
WARDRIK_TOKEN=wrk_... node statuspage.ts
```

It runs until stopped, and opens no port. The Statuspage key stays in your app. The daemon never
sees it.

## 4. Give an agent the tool

```markdown title="~/.config/wardrik/agents/status.md"
---
description: Posts to the public status page when asked.
tools: [workers/*]
policy:
  ask:
    workers/post_status: This posts publicly on the status page.
---
You post incidents on the public status page. Write for customers: what is affected, in plain
words, with no internal names.
```

The call would wait without the `ask`, as the tool isn't `readOnly`. The `ask` gives the person
deciding a reason to read.

## 5. Try it

```sh
wardrik reload
wardrik ask status "Checkout is failing for some customers. Post that we're investigating."
```

The model calls `post_status`, and the call waits. List what waits:

```sh
wardrik approval ls
```

```text
AGENT           CALL        TOOL                  WHY
default/status  call_7c2e…  workers__post_status  This posts publicly on the status page.
```

Approve it by its call ID:

```sh
wardrik approval approve status call_7c2e…
```

Your app posts it. The agent is given the incident's link, and says so. To refuse it, give a
reason, and the agent reads why:

```sh
wardrik approval deny status call_7c2e… --reason "We don't post until it's confirmed."
```

With a [Slack](/channels/slack/) notify target, the same call shows in a channel with
**Approve** and **Deny**.

## 6. Run it as a service

On the daemon's machine, run the app as a systemd user service, as the daemon runs. Put its
settings in a file only you can read:

```ini title="~/.config/statuspage.env"
WARDRIK_TOKEN=wrk_...
STATUSPAGE_PAGE_ID=...
STATUSPAGE_API_KEY=...
```

```ini title="~/.config/systemd/user/statuspage.service"
[Unit]
Description=Status page tools for Wardrik
After=wardrik.service

[Service]
WorkingDirectory=%h/statuspage
EnvironmentFile=%h/.config/statuspage.env
# where `which node` says
ExecStart=/usr/bin/node statuspage.ts
Restart=on-failure

[Install]
WantedBy=default.target
```

```sh
chmod 600 ~/.config/statuspage.env
systemctl --user daemon-reload
systemctl --user enable --now statuspage
journalctl --user -u statuspage -f
```

On another machine, or in a container, see [Host your tools](/build/host-tools/).

## What you built

- **Your key, your process.** The daemon decides the call. Your app makes it.
- **Nothing posts without a person.** The policy holds every post until someone approves it.
- **No double posts.** If your app restarts during a post, the call isn't run again on its own: it
  waits for a person. See [Deploys and restarts](/build/host-tools/#deploys-and-restarts).

## Next

- [Write tools](/build/write-tools/): who the call is for, what it cost, and running it twice.
- [Incident responder](/examples/team/incident-responder/): `post_status` beside PagerDuty, Datadog
  and the rest.
