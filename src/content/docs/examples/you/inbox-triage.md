---
title: Inbox triage
description: "Sorts your inbox every morning, drafts replies, and puts school dates on the family calendar by itself."
sidebar:
  order: 1
---

Every morning this agent reads your new mail. It archives the noise, labels what matters, drafts
replies for you to send, and adds school dates to the family calendar on its own. No email can get
it to do anything else.

Needs a Google Cloud project with the Gmail and Calendar MCP servers turned on, and a
[Slack app](/channels/slack/).

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

- Make the OAuth client in Google Cloud: a web application, with `<base_url>/oauth/callback` as its
  redirect URI (`http://127.0.0.1:4747/oauth/callback` by default).
- `members` maps your Slack ID to the daemon's admin, so you can approve from Slack.

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

The first Google call waits with a sign-in link. Sign in once. The summary lands in `#inbox`, and
the drafts wait in Gmail.

## What it shows

- Reading runs. Once a turn has read an email, only what `allow_after` names runs without you. See
  [Content from outside](/concepts/outside-content/).
- An argument rule pins one calendar. An event on any other calendar waits for you.
- Nothing can be sent: Google's Gmail server only drafts.
- `ME.md` is the agent's own file, read into every turn.
