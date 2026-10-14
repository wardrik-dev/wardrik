---
title: A marketer
description: "Drafts the newsletter and social posts from your numbers; nothing sends or publishes until you approve it."
sidebar:
  order: 3
---

This agent does a small team's weekly marketing. It reads what worked last week in Google
Analytics, drafts the newsletter in Kit and the week's posts in Buffer, and asks you in Slack before
anything goes out. Drafts are free. Sending and publishing wait for you.

## What it takes

- the daemon, [installed](/getting-started/install/), with a model provider's key, and a
  [public address](/run/public-address/) for signing in to Kit;
- a paid [Kit](https://developers.kit.com/mcp/kit-mcp) account, a
  [Buffer](https://developers.buffer.com/guides/integrations/mcp.md) API key, and a Google Cloud
  service account that can read your GA4 property;
- a [Slack app](/channels/slack/#a-slack-app) and a channel, here `#marketing`.

## The files

### config.yaml

```yaml title="~/.config/wardrik/config.yaml"
org: acme
base_url: https://agents.acme.example

mcp:
  kit:
    url: https://app.kit.com/mcp
    credential: kit
  buffer:
    url: https://mcp.buffer.com/mcp
    headers:
      authorization: Bearer ${BUFFER_API_KEY}
  analytics:
    command: pipx
    args: [run, analytics-mcp]
    env:
      GOOGLE_APPLICATION_CREDENTIALS: /etc/wardrik/ga4-reader.json
      GOOGLE_PROJECT_ID: acme-marketing

oauth:
  providers:
    kit:
      resource: https://app.kit.com/mcp

channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}

notify:
  marketing:
    channel: slack
    room: "#marketing"
    approvers: ["@maria"]
```

- Kit signs in with OAuth, and registers Wardrik as a client itself. Acme connects it once. See
  [Connect accounts](/build/accounts/).
- Google's [Analytics server](https://github.com/googleanalytics/google-analytics-mcp) is read-only.

### The policy

```yaml title="~/.config/wardrik/policies/marketing.yaml"
allow:
  - analytics/*
  - kit/list_*
  - kit/get_*
  - buffer/list_*
  - buffer/get_*
  - buffer/create_post(saveToDraft = true)
ask:
  kit/create_broadcast: This drafts or schedules a broadcast.
  kit/update_broadcast: This changes a broadcast, or schedules it.
  buffer/create_post: This publishes or queues a post.
deny:
  kit/delete_broadcast: Deleting is for people.
  kit/unsubscribe: Unsubscribing is for people.
  buffer/delete_post: Deleting is for people.
budget:
  usd: 2.00
  per: day
  on_exhausted: ask
```

- **Drafts are free.** A Buffer post saved as a draft runs without asking.
- **Anything that can go out waits.** Kit schedules a broadcast through the same tools that draft
  it, so every broadcast change waits for you.
- **What it reads is outside content.** Numbers, comments and replies from these services can't talk
  it into sending. See [Content from outside](/concepts/outside-content/).

### The agent

```markdown title="~/.config/wardrik/agents/marketer.md"
---
description: Plans and drafts the week's newsletter and posts from what worked.
tools: [analytics/*, kit/*, buffer/*, files]
context: [VOICE.md, CALENDAR.md]
channels: [slack]
policy: marketing
notify: {to: [marketing], on: [parked, failed, finished]}
triggers:
  - name: plan
    every: "0 8 * * 1"            # 08:00 UTC on Mondays
    prompt: Plan this week's newsletter and posts from last week's numbers.
---
You run marketing for Acme. VOICE.md is how we sound; CALENDAR.md is what's coming up.

Each Monday, read last week's traffic and top pages in Google Analytics, and last week's
broadcast stats in Kit. Then draft this week's newsletter as a Kit broadcast, and three posts as
Buffer drafts. Post a short plan in Slack: what you drafted and why, with one number per choice.
```

## Try it

```sh
wardrik reload
wardrik ask marketer "Plan this week."
```

Its Buffer drafts appear in Buffer at once. The newsletter waits in `#marketing` as a call with the
broadcast's subject and content as its arguments. Approve it, and it's created in Kit.

## What it shows

- **Free drafting, gated sending**, decided per call by its arguments.
- **Numbers before words.** It plans from your own analytics, read-only.
- **A voice it keeps.** `VOICE.md` and `CALENDAR.md` are its files, read into every turn.

## Details

### Kit broadcasts

Kit's MCP server creates a broadcast with `create_broadcast` and changes it with
`update_broadcast`. In Kit's API, a broadcast with a send time is scheduled, and one without is a
draft. Because one tool does both, the policy asks for every call; approve a draft and schedule it
yourself in Kit, or approve one with its send time set.

### Taking it further

- Add Google Ads' [official server](https://github.com/googleads/google-ads-mcp), read-only, to plan
  from spend too.
- Meta's [Ads MCP server](https://developers.facebook.com/documentation/ads-commerce/ads-ai-connectors/ads-mcp-server/ads-mcp-server-overview)
  can create and change campaigns. Gate every write the same way.
