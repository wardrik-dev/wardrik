---
title: Add a TypeScript tool
description: "Build a tool that posts to Statuspage, let an agent propose a post, approve it, then run the tool as a service."
sidebar:
  order: 3.1
---

Let an agent propose a Statuspage incident, then approve it before your app posts it.

You need a [running Wardrik daemon](/getting-started/install/), Node 22.18+, and a
[Statuspage](https://developer.statuspage.io/) page ID and API key.

## 1. Start an app

```sh
mkdir statuspage && cd statuspage
npm init -y && npm pkg set type=module
npm install @wardrik/sdk@0.1.0-rc.6 zod
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
    const response = await fetch(`https://api.statuspage.io/v1/pages/${page}/incidents`, {
      method: "POST",
      headers: { authorization: `OAuth ${key}`, "content-type": "application/json" },
      body: JSON.stringify({ incident }),
      signal,
    });
    if (!response.ok) throw new Error(`Statuspage returned HTTP ${response.status}`);

    const { id, shortlink } = await response.json();
    return { id, shortlink };
  },
});

const stop = new AbortController();
process.on("SIGTERM", () => stop.abort());
process.on("SIGINT", () => stop.abort());

await wardrik.work({ signal: stop.signal });
```

- It isn't `readOnly`, so every call needs approval unless a policy allows it.
- A thrown error fails the call. The model receives the error message.

## 3. Connect the tool worker

Allow the user `default/@statuspage` to serve tools to the org's agents:

```yaml title="~/.config/wardrik/config.yaml"
roles:
  tools: {rules: [{verbs: [serve], kinds: [agent]}]}
bindings:
  - {org: default, role: tools, subjects: [user:default/@statuspage]}
```

```sh
systemctl --user restart wardrik
wardrik token create statuspage --subject user:default/@statuspage
```

```sh
export STATUSPAGE_PAGE_ID=... STATUSPAGE_API_KEY=...
WARDRIK_TOKEN=wdk_... node statuspage.ts
```

This example uses the default organization, `default`. The app needs no inbound port, and
the Statuspage key stays in the app.

## 4. Enable the tool for an agent

```markdown title="~/.config/wardrik/agents/status.md"
---
description: Posts to the public status page when asked.
tools: [workers/*]
policy:
  ask:
    workers/post_status: This posts publicly on the status page.
---
You post incidents on the public status page. Write for customers, in plain words.
```

## 5. Request and approve a post

```sh
wardrik reload
wardrik ask status "Checkout is failing for some customers. Post that we're investigating."
wardrik approval ls
```

```text
AGENT   CALL        TOOL                  WHY
status  call_7c2e…  workers__post_status  This posts publicly on the status page.
```

```sh
wardrik approval approve status call_7c2e…
wardrik approval deny status call_7c2e… --reason "We don't post until it's confirmed."
```

After approval, your app posts the incident and the agent returns its link. The call ID above
is illustrative; use the ID from your pending call.

## 6. Run the tool worker as a service

```ini title="~/.config/systemd/user/statuspage.service"
[Unit]
Description=Status page tools for Wardrik
After=wardrik.service

[Service]
WorkingDirectory=%h/statuspage
EnvironmentFile=%h/.config/statuspage.env
ExecStart=/usr/bin/node statuspage.ts
Restart=on-failure

[Install]
WantedBy=default.target
```

```sh
chmod 600 ~/.config/statuspage.env   # WARDRIK_TOKEN and the Statuspage keys
systemctl --user daemon-reload
systemctl --user enable --now statuspage
```

For other machines or containers, see [Host your tools](/build/host-tools/).
