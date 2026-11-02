---
title: Slack
description: "Put an agent in a Slack channel. It answers in threads, and asks there with Approve and Deny before a call it can't make alone."
sidebar:
  order: 2
---

Make a Slack app, map your team to users, and invite the app into a channel.

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    members: {U024BE7LH: user:default/@maria, U0G9QF9C6: user:default/@jon}
```

Slack sends events over HTTPS, so the daemon needs a [public address](/run/public-address/). To
try it without one, use [Socket Mode](#testing-with-socket-mode).

## A Slack app

1. At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App › From a manifest**.
   Paste the manifest below. Change `agents.example.com` to the daemon's address.
2. Choose **Install to Workspace**. Copy the **Bot User OAuth Token** (`xoxb-...`).
3. Under **Basic Information › App Credentials**, copy the **Signing Secret**.

```yaml title="Slack app manifest"
display_information:
  name: Wardrik
  description: Agents that answer in threads, and ask before they act.
features:
  app_home:
    home_tab_enabled: false
    messages_tab_enabled: true
    messages_tab_read_only_enabled: true
  bot_user:
    display_name: Wardrik
    always_online: true
oauth_config:
  scopes:
    bot:
      - channels:history
      - channels:read
      - chat:write
      - chat:write.public
      - groups:history
      - groups:read
      - reactions:write
      - users:read
settings:
  event_subscriptions:
    request_url: https://agents.example.com/v1/channels/slack/events
    bot_events:
      - app_uninstalled
      - channel_left
      - group_left
      - member_joined_channel
      - message.channels
      - message.groups
      - tokens_revoked
  interactivity:
    is_enabled: true
    request_url: https://agents.example.com/v1/channels/slack/actions
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

- `slack` in each URL is the channel's name in `config.yaml`.
- Slack checks the events URL when you save, so the daemon must be reachable first.

Seal both secrets, and restart the daemon:

```sh
echo "xoxb-..." | wardrik vault put SLACK_BOT_TOKEN --for api_key
echo "..." | wardrik vault put SLACK_SIGNING_SECRET --for signing_secret
wardrik stop && wardrik start
```

Find each person's member ID in their Slack profile, under **Copy member ID**. Add it to
`members`.

### Testing with Socket Mode

Socket Mode needs no public address. It's for testing.

1. In the manifest, set `socket_mode_enabled: true` and drop both `request_url` lines.
2. Under **Basic Information › App-Level Tokens**, make a token with `connections:write` (`xapp-...`).
3. Use `app_token` in place of `signing_secret`:

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
```

Give each daemon its own app. Slack spreads events across every connection an app has.

## An agent in a Slack channel

List the channel in the agent's file, then `/invite @Wardrik` in Slack:

```yaml
channels: [slack]
```

> :wave: **books** answers here now.
> `[Answer every message]` `[⋯]`

- **Answer every message** answers each message, each in its own thread.
- **⋯** has **Use another agent** and **Stop answering here**.

## Threads in Slack

> **maria:** @Wardrik how much Barolo is left? :eyes:
> ↳ **Wardrik:** Two cases, both 2019.

- Replies in the thread need no mention.
- :eyes: means the agent took the message. :white_check_mark: means it answered.
- The thread's status shows what the agent is doing.

## What a notice says in Slack

A waiting call shows its tool, the policy's question and its arguments, with **Approve**, **Deny**
and a box for a note. Once decided, the buttons give way to who decided:

> Denied `deploy` by @jon: Deploy to staging first, and show me the diff.

## Who approves

- Whoever asked for the turn may always decide its calls.
- Anyone else needs a binding that lets their user approve on that agent:

```yaml title="~/.config/wardrik/config.yaml"
roles:
  approver: {rules: [{verbs: [approve, deny, decide], kinds: [agent], names: [books]}]}
bindings:
  - {org: default, role: approver, subjects: [user:default/@maria]}
```

A trigger's turn has nobody who asked. Decide it with `wardrik approval approve`.

## The app says nothing

If the app was invited while the daemon was down, `/remove @Wardrik` and invite it again. Then
check:

- **Event Subscriptions** shows the request URL verified;
- `wardrik doctor`, which checks the tokens with Slack;
- `wardrik logs`.

To run the same app inside your own Elixir app, see `WardrikSlack`.
