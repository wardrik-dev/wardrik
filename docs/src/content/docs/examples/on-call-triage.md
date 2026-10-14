---
title: First response for an on-call team
description: An org's agent that picks up each new incident, reads the runbook and what changed, and proposes a first response that an on-call engineer approves in Slack, with a record of every call it made.
sidebar:
  order: 5
---

An agent that belongs to a team rather than a person. Every five minutes it looks for new
incidents in Linear, finds the runbook that fits, looks at what changed on GitHub around when the
incident began, and drafts a first response as a comment on the issue. The comment waits in the
on-call channel until one of the on-call engineers approves it.

It shows what a team needs from an agent before it lets one near production: rules a reviewer can
read, approvals only named people can give, a budget, a record of everything it did, and other
teams on the same daemon kept apart.

## What it takes

- the daemon, [installed](/getting-started/install/) and running, with a model provider's key as the
  [Quickstart](/getting-started/quickstart/#1-install) gives it one;
- a Linear API key and a GitHub token for a machine account, both able to read, and Linear's able
  to comment;
- the team's runbooks as Markdown files in a directory on the daemon's machine;
- a Slack app with a bot token and an app-level token, made as
  [Slack](/channels/slack/#a-slack-app) makes one, in the on-call channel.

## The servers and the channel

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

- `only` gives the agent the tools it needs and no others: Linear's reading tools and
  `save_comment`, and GitHub's reading tools alone, so nothing it reads can get it to merge, push or
  close anything.
- `gated` makes `save_comment` wait on a person unless a rule allows it by name. What an issue says
  is content from outside, written by whoever filed it, so once the agent has read one, a comment
  waits on a person however a policy allows it.
- `trusted: true` says the runbooks are the team's own, so reading them labels nothing; `only`
  gives the agent the server's reading tools alone.
- `approvers` are the on-call engineers' Slack ids. Anyone else in the channel who presses a button
  is told only the approvers can answer.

Restart the daemon after changing `config.yaml`, and check each server:

```sh
systemctl --user restart wardrik
wardrik doctor
```

## The policy

A policy is a file the team can review like any other change:

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

Reading is allowed by name, commenting asks, and what no rule names, such as a tool added to a
server's `only` next month, asks too. Deleting its own files is refused outright, and the model is
told why.

## The agent

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

Read the agent files again; the first sweep runs five minutes later:

```sh
wardrik reload
wardrik show triage
```

When it has a comment to make, `#oncall` gets the call, its arguments, the comment it would post
and on which issue, with Approve and Deny. Pressing one decides it, and the message says who did.
A denied comment tells the agent "Denied in Slack by" whoever pressed it, and it carries on.

## A record of everything

Every message, model reply, tool call, decision and refusal is an event on the agent's stream, as a
CloudEvent with OpenTelemetry's names and a W3C `traceparent`. A token that can only read follows it
into whatever keeps your logs:

```sh
wardrik token create audit --scope acme/ --can read
curl -N -H "authorization: Bearer $AUDIT_TOKEN" -H "accept: text/event-stream" \
  http://127.0.0.1:4747/v1/agents/acme/triage/events
```

A client that reconnects with the last `id:` it saw misses nothing kept. A decision made in Slack is
in the stream as `interrupt.resolved`, and a refused call as `tool_call.denied`, with the rule's
reason. See [The event stream](/concepts/events/).

## Another team, the same daemon

An org is the boundary between agents. A second team's agent names its org, and gets servers,
channels and credentials of its own:

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

An agent of `globex` cannot be given acme's servers or route its notices to acme's channel: its file
does not read. A token scoped to `globex/` answers acme's agents as ones that do not exist. See
[Orgs](/run/security/#orgs).

## Through a lost machine

On three machines with the store in Postgres, the agent carries on when the one it runs on is
lost, with a comment that waits on the on-call channel still waiting, and its sweep still on time:

```yaml title="~/.config/wardrik/config.yaml"
storage:
  postgres:
    url: ${DATABASE_URL}

cluster:
  nodes: [wardrik@ops1, wardrik@ops2, wardrik@ops3]
```

Every node runs the MCP servers its agents use, so `/srv/runbooks` is needed on each. See
[Run a cluster](/run/cluster/) and [Storage](/run/storage/).

## What it shows

- **Rules as data.** The policy is a file outside the agent, decided before each call, and the same
  on every node. See [Policy and approvals](/concepts/policy/).
- **Named approvers.** A parked call reaches Slack with its arguments, and only `approvers` decide
  it. See [Who approves](/channels/slack/#who-approves).
- **Trust by source.** The team's runbooks are not labelled `outside`; issues anyone can file are. See
  [Content from outside](/concepts/outside-content/).
- **A budget per agent.** The agent stops and asks once it has spent its day's $20. See
  [Budgets](/concepts/budgets/).
- **An audit trail.** One stream of CloudEvents, read with a token that can do nothing else.
- **Orgs.** Servers, notice targets, credentials and tokens stay within the org they serve.

## Taking it further

- Respond the moment an incident is filed, rather than within five minutes: a `webhook` trigger
  that Linear, Sentry or Alertmanager calls asks the agent as each arrives. See
  [Pointing a service at a trigger](/build/triggers/#pointing-a-service-at-a-trigger).
- Point a second trigger at a weekly review: `every: "0 9 * * 1"`, asking for what the week's
  incidents had in common, and keep the answer in a file the team reads.
- Give the agent a runbook step it may take without asking, such as restarting one service, as a
  [tool worker](/build/tool-workers/) whose tool the policy allows by name.
