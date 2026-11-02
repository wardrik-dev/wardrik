---
title: Incident responder
description: "Paged by PagerDuty, it investigates across your monitoring and proposes the fix for on-call to approve in Slack."
sidebar:
  order: 1
---

When PagerDuty pages, this agent reads the alert, checks Datadog, finds the deploy that changed
things, and posts what it found to `#incidents`. It proposes the fix as a call: restart the pod,
scale up, or roll back. On-call approves it from Slack.

Needs a [public address](/run/public-address/) PagerDuty can reach, keys for PagerDuty, Datadog,
GitHub and Linear, a kubeconfig, and a [Slack app](/channels/slack/).

## The files

```yaml title="~/.config/wardrik/config.yaml"
org: acme
base_url: https://agents.acme.example

mcp:
  pagerduty:
    url: https://mcp.pagerduty.com/mcp
    headers: {authorization: "Token token=${PAGERDUTY_API_KEY}"}
  datadog:
    url: https://mcp.datadoghq.com/v1/mcp?toolsets=core
    headers: {DD_API_KEY: "${DD_API_KEY}", DD_APPLICATION_KEY: "${DD_APPLICATION_KEY}"}
  github:
    url: https://api.githubcopilot.com/mcp/
    headers: {authorization: "Bearer ${GITHUB_TOKEN}"}
    only: [list_commits, get_commit, actions_list, actions_run_trigger]
  k8s:
    command: npx
    args: [-y, kubernetes-mcp-server@latest]
    only: [pods_list, pods_log, events_list, pods_delete, resources_scale]
  linear:
    url: https://mcp.linear.app/mcp
    headers: {authorization: "Bearer ${LINEAR_API_KEY}"}

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    members: {U024BE7LH: user:acme/@maria, U0G9QF9C6: user:acme/@devon, U07QJ2N4K: user:acme/@sam}

notify:
  targets:
    incidents: {channel: slack, room: "#incidents"}

roles:
  on-call:
    rules: [{verbs: [ask, read, events, decide], kinds: [agent], names: [oncall]}]
  worker:
    rules: [{verbs: [serve], kinds: [agent], names: [oncall]}]
bindings:
  - {org: acme, role: on-call, subjects: [user:acme/@maria, user:acme/@devon, user:acme/@sam]}
  - {org: acme, role: worker, subjects: [user:acme/@statuspage]}
```

- `members` maps each engineer's Slack ID to a user. The `on-call` binding lets them approve.
- `worker` lets the status page app below offer its tool to `oncall`, and nothing else.
- `only` leaves out the tools the agent never needs, such as merging or deleting a deployment.

Statuspage has no MCP server, so a small app posts to it with the
[TypeScript SDK](/build/tool-workers/):

```ts title="statuspage.ts"
import { Wardrik } from "@wardrik/sdk";
import { z } from "zod";

const wardrik = new Wardrik({ name: "statuspage" });

wardrik.tool({
  name: "post_status",
  description: "Open an incident on the public status page, with its first update.",
  input: z.object({
    name: z.string(),
    status: z.enum(["investigating", "identified", "monitoring", "resolved"]),
    body: z.string(),
  }),
  run: async (incident, { signal }) => {
    const url = `https://api.statuspage.io/v1/pages/${process.env.STATUSPAGE_PAGE_ID}/incidents`;
    const response = await fetch(url, {
      method: "POST",
      headers: { authorization: `OAuth ${process.env.STATUSPAGE_API_KEY}`, "content-type": "application/json" },
      body: JSON.stringify({ incident }),
      signal,
    });
    if (!response.ok) throw new Error(`Statuspage answered ${response.status}`);
    return response.json();
  },
});

await wardrik.work();
```

It isn't `readOnly`, so every post waits for a person. The Statuspage key stays in the app.

```yaml title="~/.config/wardrik/policies/incident.yaml"
allow:
  - pagerduty/browse_*
  - datadog/*
  - github/list_*
  - github/get_commit
  - github/actions_list
  - k8s/pods_list
  - k8s/pods_log
  - k8s/events_list
ask:
  pagerduty/manage_incidents: This changes the incident in PagerDuty.
  k8s/pods_delete: This restarts the pod.
  k8s/resources_scale(scale <= 20): This scales a deployment.
  "github/actions_run_trigger(method = run_workflow, workflow_id = rollback.yml)": This rolls back.
  workers/post_status: This posts publicly on the status page.
deny:
  k8s/resources_scale(scale > 20): More than 20 replicas goes through capacity planning.
allow_after:
  outside: [linear/save_issue]
budget: {usd: 3.00, per: turn, on_exhausted: ask}
```

```markdown title="~/.config/wardrik/agents/oncall.md"
---
description: First responder for every page. Investigates, then proposes the fix.
tools: [pagerduty/*, datadog/*, github/*, k8s/*, linear/*, workers/*, files]
context: [INCIDENTS.md]
policy: incident
timeout: 1200
notify: {to: [incidents], on: [parked, failed, finished]}
triggers:
  - name: pagerduty
    webhook: {secret: "${PAGERDUTY_HOOK_SECRET}"}
    prompt: PagerDuty paged. The event is below. Respond to it.
---
You are the first responder for Acme's production systems. When paged:

1. Read the incident. Check INCIDENTS.md for the same alert before.
2. Check Datadog's logs, metrics and traces, and the deploys in the hour before.
3. Post the likely cause, with evidence and links.
4. Propose the smallest fix as the call that does it. Draft a status page update if customers
   can see it.
5. Once it's resolved, file the postmortem in Linear and add a line to INCIDENTS.md.
```

## Try it

```sh
echo "$PAGERDUTY_API_KEY" | wardrik vault put PAGERDUTY_API_KEY --for header
# ...and DD_API_KEY, DD_APPLICATION_KEY, GITHUB_TOKEN, LINEAR_API_KEY, the Slack token and secret
openssl rand -hex 32 | tee hook.secret | wardrik vault put PAGERDUTY_HOOK_SECRET --org acme --for signing_secret
systemctl --user restart wardrik
wardrik doctor
wardrik agent show oncall           # note its ID, agt_...
```

Run the status page app with a token of its own:

```sh
wardrik token create statuspage --subject user:acme/@statuspage
npm install @wardrik/sdk@0.1.0-rc.2 zod
WARDRIK_URL=https://agents.acme.example WARDRIK_TOKEN=... node statuspage.ts
```

In PagerDuty, add a Generic Webhook (v3) for `incident.triggered` at:

```text
https://agents.acme.example/v1/hooks/agt_.../pagerduty/<the secret>
```

Or send one yourself:

```sh
curl -X POST "https://agents.acme.example/v1/hooks/agt_.../pagerduty/$(cat hook.secret)" \
  -H "content-type: application/json" \
  -d '{"event": {"event_type": "incident.triggered", "data": {"title": "checkout-api: p99 over 2s"}}}'
```

`#incidents` shows what it found, then the proposed fix with **Approve** and **Deny**.

## What it shows

- A webhook starts a turn the moment PagerDuty fires. See [Trigger an agent](/build/triggers/).
- Investigating runs alone. Every change waits for on-call, with its arguments shown.
- Argument rules set exact limits: replicas, and which workflow.
- Logs are outside content, so a crafted error message can't start a rollback. The postmortem is
  the one thing `allow_after` lets through.
- `per: turn` caps each page at $3. See [Budgets](/concepts/budgets/).
