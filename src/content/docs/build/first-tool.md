---
title: Your first tool, end to end
description: "Build a tool that posts to Statuspage, let an agent propose a post, approve it, then run the tool as a service."
sidebar:
  order: 3.1
---

You'll build `post_status`, a tool that opens an incident on a public status page. You need the
daemon [installed](/getting-started/install/), Node 22.18 or later, and a
[Statuspage](https://developer.statuspage.io/) page ID and API key.

## 1. Start an app

```sh
mkdir statuspage && cd statuspage
npm init -y && npm pkg set type=module
npm install @wardrik/sdk@0.1.0-rc.2 zod
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
    if (!response.ok) throw new Error(`Statuspage answered ${response.status}`);

    const { id, shortlink } = await response.json();
    return { id, shortlink };
  },
});

const stop = new AbortController();
process.on("SIGTERM", () => stop.abort());
process.on("SIGINT", () => stop.abort());

await wardrik.work({ signal: stop.signal });
```

- It isn't `readOnly`, so every call waits for a person unless a policy allows it.
- A thrown error fails the call. The model reads the message.

## 3. Connect it

Let the user `default/@statuspage` serve tools to the org's agents:

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

`default` is the org `config.yaml` names, unless it names another. The app opens no port. The
Statuspage key never leaves it.

## 4. Give an agent the tool

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

## 5. Try it

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

Approved, your app posts it, and the agent gets the link.

## 6. Run it as a service

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

Elsewhere, or in a container, see [Host your tools](/build/host-tools/).
