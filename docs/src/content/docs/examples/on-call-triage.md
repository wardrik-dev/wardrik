---
title: First response for an on-call team
description: A team's agent that proposes a first response to each new incident, for an on-call engineer to approve in Slack.
sidebar:
  order: 5
---

Every five minutes this team agent checks Linear for new incidents, reads the matching runbook and
recent GitHub changes, and drafts a comment. The comment waits in `#oncall` until an on-call engineer
approves it.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key from the
  [Quickstart](/getting-started/quickstart/#1-install);
- a Linear API key that can read and comment, and a GitHub token for a machine account that can read;
- the team's runbooks as Markdown files on the daemon's machine;
- a [Slack app](/channels/slack/#a-slack-app) with a bot token and an app-level token, in the on-call
  channel.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
org: acme

mcp:
  linear:
    url: https://mcp.linear.app/mcp
    headers:
      authorization: Bearer ${LINEAR_TOKEN}
    only: [list_teams, list_issues, get_issue, list_comments, save_comment]
    gated: [save_comment]
  github:
    url: https://api.githubcopilot.com/mcp/
    headers:
      authorization: Bearer ${GITHUB_TOKEN}
    only: [list_commits, get_commit, list_pull_requests, search_pull_requests, pull_request_read]
  runbooks:
    command: npx
    args: [-y, "@modelcontextprotocol/server-filesystem", /srv/runbooks]
    only: [read_text_file, list_directory, search_files]
    trusted: true

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}

notify:
  oncall:
    channel: slack
    room: "#oncall"
    approvers: ["@maria", "@jon", "@priya"]
```

- `only` keeps GitHub read-only: nothing it reads can make it merge or push.
- `gated` makes `save_comment` wait for a person.
- `trusted: true` marks the runbooks as the team's own, so reading them labels nothing.
- Only `approvers` can answer.

Restart and check:

```sh
systemctl --user restart wardrik
wardrik doctor
```

### The policy

```yaml title="~/.config/wardrik/policies/oncall.yaml"
allow:
  - runbooks/*
  - linear/list_*
  - linear/get_*
  - github/*
  - read_file
  - list_files
  - search_files
  - write_file(MEMORY.md)
  - edit_file(MEMORY.md)
ask:
  linear/save_comment: This comments on the incident.
deny:
  delete_file(*): Keep what you have written.
default: ask
budget:
  usd: 20.00
  per: day
  on_exhausted: ask
```

Reading runs, commenting asks, anything unnamed asks, and deleting is refused.

### The agent

```markdown title="~/.config/wardrik/agents/triage.md"
---
description: First response to incidents, for whoever is on call.
model: anthropic:claude-sonnet-5
tools: [linear/*, github/*, runbooks/*, files]
context: [MEMORY.md]
policy: oncall
timeout: 900
triggers:
  - name: sweep
    every: 5m
    prompt: Look for new incidents.
notify: oncall
---
You give the first response to incidents for acme's on-call engineers.

An incident is an issue in Linear's Incidents team. For each one you have not seen: find the runbook
that fits it, look on GitHub for what was merged or deployed in the repositories it names in the
hours before it began, and comment on the issue with what you found, the runbook's first steps, and
what you would check next. Be brief, and say how sure you are.

Keep the incidents you have seen in MEMORY.md, each with a line on what you said. If nothing is
new, answer in one line.
```

## Try it

```sh
wardrik reload
wardrik show triage
```

Within five minutes, `#oncall` gets its first proposed comment, with Approve and Deny.

## What it shows

- **Rules as data**, reviewable like code. See [Policy](/concepts/policy/).
- **Named approvers.** See [Who approves](/channels/slack/#who-approves).
- **Trust by source.** Runbooks aren't `outside`; issues are. See
  [Content from outside](/concepts/outside-content/).
- **A budget** of $20 a day. See [Budgets](/concepts/budgets/).
- **An audit trail** and **orgs**, below.

## Details

### A record of everything

Every message, call, decision and refusal is a CloudEvent with a W3C `traceparent`. A read-only token
follows the stream into your logs:

```sh
wardrik token create audit --scope acme/ --can read
curl -N -H "authorization: Bearer $AUDIT_TOKEN" -H "accept: text/event-stream" \
  http://127.0.0.1:4747/v1/agents/acme/triage/events
```

Reconnecting with the last `id:` misses nothing. See [The event stream](/concepts/events/).

### Another team, the same daemon

A second team's agent names its own org, with its own servers and channels:

```yaml title="~/.config/wardrik/config.yaml"
mcp:
  globex-linear:
    url: https://mcp.linear.app/mcp
    headers:
      authorization: Bearer ${GLOBEX_LINEAR_TOKEN}
    org: globex

notify:
  globex-oncall:
    org: globex
    channel: slack
    room: "#globex-oncall"
```

A `globex` agent can't reach acme's servers, and a `globex/` token can't see acme's agents. See
[Orgs](/run/orgs/).

### Through a lost machine

On three machines with Postgres, it carries on when one is lost, with waiting comments intact:

```yaml title="~/.config/wardrik/config.yaml"
storage:
  postgres:
    url: ${DATABASE_URL}

cluster:
  nodes: [wardrik@ops1, wardrik@ops2, wardrik@ops3]
```

Each node needs `/srv/runbooks`. See [Run a cluster](/run/cluster/).

### Taking it further

- Respond instantly with a [webhook trigger](/build/triggers/#pointing-a-service-at-a-trigger) from
  Linear, Sentry or Alertmanager.
- Add a weekly review trigger.
- Let it restart a service without asking, as a [tool worker](/build/tool-workers/) the policy allows.
