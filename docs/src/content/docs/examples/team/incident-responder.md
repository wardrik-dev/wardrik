---
title: Incident responder
description: "A PagerDuty webhook starts the agent. It investigates your monitoring and proposes a fix for on-call to approve in Slack."
sidebar:
  order: 1
---

A PagerDuty webhook starts a turn. The agent reads the alert, queries Datadog, finds the related
deploy, and posts its findings to `#incidents`. It proposes a fix as a tool call: restart a pod,
scale up, or roll back. On-call approves the call in Slack.

Requires a [public address](/run/public-address/) for PagerDuty, keys for PagerDuty, Datadog,
GitHub and Linear, a kubeconfig, and a [Slack app](/build/slack/).

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
    domains: {acme.com: acme}

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

- `domains` makes `maria@acme.com` the user `user:acme/@maria`. The `on-call` binding allows its
  users to approve.
- `worker` allows the status page app below to serve tools to `oncall` only.
- `only` excludes tools the agent doesn't need, such as merging or deleting a deployment.

Statuspage has no MCP server, so it uses `statuspage.ts` from
[Your first tool](/build/first-tool/#2-write-the-tool). Every post needs approval.

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
  "github/actions_run_trigger(method = run_workflow, workflow_id = rollback.yml)": This runs the rollback workflow.
  workers/post_status: This posts publicly on the status page.
deny:
  k8s/resources_scale(scale > 20): Scaling above 20 replicas requires capacity planning.
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

Run the status page app with its own token:

```sh
wardrik token create statuspage --subject user:acme/@statuspage
npm install @wardrik/sdk@0.1.0-rc.5 zod
WARDRIK_URL=https://agents.acme.example WARDRIK_TOKEN=... node statuspage.ts
```

In PagerDuty, add a Generic Webhook (v3) for `incident.triggered` at:

```text
https://agents.acme.example/v1/hooks/agt_.../pagerduty/<the secret>
```

Or send a test request:

```sh
curl -X POST "https://agents.acme.example/v1/hooks/agt_.../pagerduty/$(cat hook.secret)" \
  -H "content-type: application/json" \
  -d '{"event": {"event_type": "incident.triggered", "data": {"title": "checkout-api: p99 over 2s"}}}'
```

`#incidents` shows the findings, then the proposed fix with **Approve** and **Deny**.

## How it works

- A webhook trigger starts a turn when PagerDuty sends the event. See [Trigger an agent](/build/triggers/).
- Read-only calls run without approval. Every change needs on-call's approval, with its arguments
  shown.
- Argument rules set exact limits: replica count, and which workflow.
- Logs are untrusted content, so rollback calls still require approval after the agent reads them.
  `allow_after` allows only the postmortem.
- `per: turn` requires approval for further model calls after spending reaches $3 per incident.
  The call crossing the threshold still completes. See [Budgets](/concepts/budgets/).
