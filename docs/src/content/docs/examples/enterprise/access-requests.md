---
title: Access requests
description: "Employees ask for access in Slack; it grants it through Okta once approved, and takes it back when it expires."
sidebar:
  order: 1
---

Someone needs write access to the payments repository for the afternoon. They ask in `#access`.
The agent finds the right Okta group, proposes adding them, and an approver presses Approve. When
the time is up, it removes them on its own. Every grant, approval and removal is on the record.

Reading the directory runs alone. Granting access waits for an approver. Production admin is never
granted by the agent. Taking access away runs alone, because the worst it can do is remove access.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key;
- an Okta API service app for [Okta's MCP server](https://github.com/okta/okta-mcp-server), with a
  private key for browserless sign-in;
- a [Slack app](/channels/slack/#a-slack-app) and a channel for it, here `#access`.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
org: acme

mcp:
  okta:
    command: uvx
    args: [okta-mcp-server]
    env:
      OKTA_ORG_URL: https://acme.okta.com
      OKTA_CLIENT_ID: ${OKTA_CLIENT_ID}
      OKTA_KEY_ID: ${OKTA_KEY_ID}
      OKTA_PRIVATE_KEY: ${OKTA_PRIVATE_KEY}
      OKTA_SCOPES: okta.users.read okta.groups.read okta.groups.manage okta.logs.read
    only: [list_users, get_user, list_groups, get_group, list_user_groups, list_group_users,
           get_logs, add_user_to_group, remove_user_from_group]

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
    approvers: ["@maria", "@priya"]
```

- Okta's server loads only the tools its scopes allow. `only` narrows them to reading, and adding
  and removing group members.
- `approvers` are who may grant access: a fixed list for the channel, here IT and security leads.

Seal the keys and restart:

```sh
wardrik vault put OKTA_CLIENT_ID       # and OKTA_KEY_ID, OKTA_PRIVATE_KEY
systemctl --user restart wardrik
wardrik doctor
```

### The policy

```yaml title="~/.config/wardrik/policies/access.yaml"
allow:
  - okta/list_*
  - okta/get_*
ask:
  okta/add_user_to_group: This grants access.
deny:
  okta/add_user_to_group(group_id = 00gPRODADMIN): Production admin is granted by people, not agents.
allow_after:
  outside: [okta/remove_user_from_group]
```

- **Granting waits.** Each grant is a call an approver decides, with the user and group in front of
  them.
- **Some groups never.** An argument rule refuses production admin, whoever asks and however.
- **Revoking runs.** Okta's answers are [outside content](/concepts/outside-content/), which holds
  every change for a person. `allow_after` lets removals through anyway: a stranger can't turn a
  removal against you.

### The agent

```markdown title="~/.config/wardrik/agents/access.md"
---
description: Grants just-in-time access through Okta groups, and takes it back when it expires.
tools: [okta/*, files]
policy: access
channels: [slack]
context: [CATALOG.md, GRANTS.md]
triggers:
  - name: expire
    every: 15m
    prompt: Remove everyone whose grant in GRANTS.md has expired, then update GRANTS.md.
---
You grant temporary access for Acme. CATALOG.md lists the groups people may ask for, who each is
for, and the longest each may be held.

When someone asks for access, find them in Okta, and find the group in CATALOG.md that gives what
they need. Ask how long they need it if they haven't said, within the group's limit. Then propose
adding them to the group. If it isn't in CATALOG.md, say who to ask instead.

Once a grant is approved, add a line to GRANTS.md: the person, the group, who approved, and when it
expires.
```

- **The catalog is policy you write.** `CATALOG.md` lists what can be requested and for how long.
- **Expiry is a clock.** The `expire` trigger runs every 15 minutes and removes what's due. An agent
  file can't change its own triggers, so one sweeping trigger covers every grant. See
  [Trigger an agent](/build/triggers/).

## Try it

Write `CATALOG.md` with the agent, invite the bot to `#access`, and ask:

```sh
wardrik reload
wardrik ask access "Write CATALOG.md: payments-repo-write is for payments engineers, up to 8 hours.
billing-readonly is for anyone in finance, up to 7 days."
```

In `#access`:

> **@Wardrik** I need payments-repo-write for the afternoon to ship the refund fix.

It replies in the thread with the grant it proposes, as a call waiting for an approver with
**Approve** and **Deny**. Once it's approved, the person is in the group. Four hours later, the
sweep removes them.

## What it shows

- **Least privilege by default.** Access is granted for a time, and taken back by a clock.
- **Approval with the details.** The approver sees the person and the group before anything changes.
- **Hard limits.** An argument rule keeps the agent away from production admin entirely.
- **A safe one-way door.** Removing access runs even after reading outside content; granting never
  does.
- **An audit trail.** Every grant, approval and removal is an [event](/concepts/events/), with who
  approved it.

## Details

### GitHub access

GitHub's MCP server can read teams and collaborators but can't change them. Give GitHub access
through an Okta group synced to a GitHub team, so the grant here is the grant there.

### Who approves

A channel's `approvers` are one list for the whole channel. To have each team approve its own
access, give each team its own room and [notice target](/build/notices/) with its own approvers.

### Getting the record out

- Each agent's events, including every decision and who made it, stream over the
  [HTTP API](/reference/http-api/#events).
- An export reads every log a token may read, for a SIEM. See
  [Exports](/reference/http-api/#exports).

### Taking it further

- Ask for a reason with each request, and keep it in `GRANTS.md` for the review.
- Post a weekly summary of who held what with a [clock trigger](/build/triggers/) and
  [notices](/build/notices/).
