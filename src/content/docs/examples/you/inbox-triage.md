---
title: Inbox triage
description: "Triages your inbox every morning, drafts replies, and adds school dates to the family calendar without approval."
sidebar:
  order: 1
---

Every morning this agent reads your new mail. It archives noise, labels the rest, and drafts
replies for you to send. It adds school dates to the family calendar without approval. The policy
denies or requires approval for everything else.

Requires a Google Cloud project with the Gmail and Calendar MCP servers enabled, and a
[Slack app](/build/slack/).

## The files

```yaml title="~/.config/wardrik/config.yaml"
mcp:
  gmail: {url: https://gmailmcp.googleapis.com/mcp/v1, credential: google}
  gcal: {url: https://calendarmcp.googleapis.com/mcp/v1, credential: google}

oauth:
  providers:
    google:
      issuer: https://accounts.google.com
      resource: https://gmailmcp.googleapis.com/mcp/v1
      client_id: ${GOOGLE_CLIENT_ID}
      client_secret: ${GOOGLE_CLIENT_SECRET}
      scopes:
        - https://www.googleapis.com/auth/gmail.readonly
        - https://www.googleapis.com/auth/gmail.compose
        - https://www.googleapis.com/auth/calendar

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    members: {U024BE7LH: user:admin}

notify:
  targets:
    inbox: {channel: slack, room: "#inbox"}
```

- Create the OAuth client in Google Cloud as a web application. Set its redirect URI to
  `<base_url>/oauth/callback` (`http://127.0.0.1:4747/oauth/callback` by default).
- `members` maps your Slack ID to the admin user, so you can approve in Slack.

```yaml title="~/.config/wardrik/policies/inbox.yaml"
allow_after:
  outside:
    - gmail/label_thread
    - gmail/unlabel_thread
    - gmail/create_draft
    - gcal/create_event(calendarId = family08a2@group.calendar.google.com)
deny:
  gmail/trash_*: Nothing in the inbox is deleted.
  gcal/delete_event: Nothing on a calendar is deleted.
budget: {usd: 1.00, per: day}
```

```markdown title="~/.config/wardrik/agents/inbox.md"
---
description: Triages my inbox each morning, drafts replies, and keeps the family calendar.
tools: [gmail/*, gcal/*, files]
context: [ME.md]
policy: inbox
notify: {to: [inbox], on: [parked, failed, finished]}
triggers:
  - name: morning
    every: "0 6 * * *"
    timezone: Europe/London
    prompt: Triage what came in since yesterday.
---
You keep my inbox. ME.md says who I am and the family calendar's id.

Each morning: archive newsletters and notifications I never open. Label the rest Reply, Read or
Waiting. Draft a short reply for each Reply thread. When an email from school, clubs or family gives
a date, add it to the family calendar. Then post a summary.
```

## Try it

```sh
systemctl --user restart wardrik
wardrik ask inbox "Write ME.md: I'm Jo. The family calendar is family08a2@group.calendar.google.com."
wardrik ask inbox "Triage my inbox now."
```

The first Google call pauses with a sign-in link. Sign in once. The summary is posted to `#inbox`,
and the drafts are saved in Gmail.

## What it shows

- Reads run without approval. After a turn reads an email, only tools in `allow_after` run without
  approval. See [Content from outside](/concepts/outside-content/).
- An argument rule limits `create_event` to one calendar. Events on other calendars need approval.
- The Gmail server has no send tool, only drafts.
- `ME.md` is in the agent's workspace and loaded into every turn.
