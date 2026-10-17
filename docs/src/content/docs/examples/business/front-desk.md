---
title: A front desk
description: "Answers the shared inbox and books appointments: replies wait as drafts, and no email can get a refund issued."
sidebar:
  order: 4
---

This agent works the front desk of a small shop: it reads the shared inbox, sorts it, drafts every
reply from what it knows about your business, and books appointments in Square. Your staff read
the drafts and send them. Customers' emails can ask for anything; they can't get a refund issued.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key, and a
  [public address](/run/public-address/) for signing in to Google;
- Google Workspace, with Google's
  [Gmail MCP server](https://developers.google.com/workspace/gmail/api/reference/mcp) enabled and an
  OAuth client marked for an AI agent;
- Square, with a Square access token for Square's
  [MCP server](https://github.com/square/square-mcp-server);
- a [Slack app](/channels/slack/#a-slack-app) and a channel, here `#front-desk`.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
org: acme
base_url: https://agents.acme.example

mcp:
  gmail:
    url: https://gmailmcp.googleapis.com/mcp/v1
    credential: gmail
  square:
    command: npx
    args: [square-mcp-server, start]
    env:
      ACCESS_TOKEN: ${SQUARE_ACCESS_TOKEN}

oauth:
  providers:
    gmail:
      resource: https://gmailmcp.googleapis.com/mcp/v1
      issuer: https://accounts.google.com
      client_id: ${GOOGLE_CLIENT_ID}
      client_secret: ${GOOGLE_CLIENT_SECRET}
      scopes:
        - https://www.googleapis.com/auth/gmail.readonly
        - https://www.googleapis.com/auth/gmail.compose

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}

notify:
  front-desk:
    channel: slack
    room: "#front-desk"
    approvers: ["@maria", "@sam"]
```

- Google's server signs in with an OAuth client you make in Google Cloud. Register
  `https://agents.acme.example/oauth/callback/gmail` as its redirect URI. Acme connects the shared
  inbox once. See [Connect accounts](/build/accounts/).
- Square's server has one tool, `make_api_request`, that names the Square service and method.

### The policy

```yaml title="~/.config/wardrik/policies/front-desk.yaml"
allow:
  - gmail/search_threads
  - gmail/get_*
  - gmail/list_*
  - gmail/create_draft
  - gmail/label_thread
  - gmail/unlabel_thread
  - square/get_*
allow_after:
  outside:
    - gmail/create_draft
    - gmail/label_thread
    - gmail/unlabel_thread
    - square/make_api_request(service = bookings, method = searchAvailability)
    - square/make_api_request(service = bookings, method = list)
    - square/make_api_request(service = bookings, method = create)
ask:
  square/make_api_request(service = bookings, method = update): This moves a booking.
  square/make_api_request(service = bookings, method = cancel): This cancels a booking.
deny:
  square/make_api_request(service = refunds): Refunds are for people.
  square/make_api_request(service = payments): Payments are for people.
  gmail/trash_*: Deleting mail is for people.
```

- **Every email is outside content**, so after reading one, only what `allow_after` names runs on its
  own: drafting, labelling, and booking a new appointment. See
  [Content from outside](/concepts/outside-content/).
- **Moving or cancelling waits** for your staff in Slack.
- **Money is refused.** No email, however it's worded, gets a refund or a payment made.
- **Replies are drafts.** Google's Gmail server has no send tool; your staff send what it drafts.

### The agent

```markdown title="~/.config/wardrik/agents/front-desk.md"
---
description: Works the shared inbox and the appointment book.
tools: [gmail/*, square/*, files]
context: [ABOUT.md]
channels: [slack]
policy: front-desk
notify: {to: [front-desk], on: [parked, failed]}
triggers:
  - name: inbox
    every: 15m
    prompt: Work through new mail in the inbox.
---
You run the front desk for Acme Bike Repair. ABOUT.md has our hours, prices and policies.

For each new thread: label it (Booking, Question, Complaint, Other). Draft a reply from ABOUT.md. If
someone wants an appointment, find a free slot in Square, book it, and say so in the draft. Never
promise a refund; say a person will look at it, and label the thread Complaint.
```

## Try it

```sh
wardrik reload
wardrik ask front-desk "Work through new mail in the inbox."
```

Send the shop a test email asking for a tune-up on Saturday. Within 15 minutes it's labelled
Booking, the appointment is in Square, and a reply waits in Drafts for someone to send.

## What it shows

- **Narrow autonomy after reading strangers' mail.** `allow_after` names exactly what may run.
- **Argument rules on one generic tool.** Square's single tool is ruled by service and method.
- **A hard line on money**, however an email is worded.
- **People stay the sender.** Drafts in, replies out by hand.

## Details

### Why reads are in `allow_after` too

Square's one tool both reads and writes, so it's gated, and after an email even its reads would wait.
Naming the reads in `allow_after` lets the agent check the calendar while it works.

### Taking it further

- Add Google Calendar's [MCP server](https://developers.google.com/workspace/calendar/api/guides/configure-mcp-server)
  for a shop that books there instead.
- A [webhook trigger](/build/triggers/#receiving-a-webhook) from Gmail's push notifications can
  replace the 15-minute check.
