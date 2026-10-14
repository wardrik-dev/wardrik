---
title: Slack
description: "Put an agent in a Slack channel: it answers in threads and asks there, with Approve and Deny, before a call it can't make alone."
sidebar:
  order: 2
---

Make a Slack app for Wardrik, invite it into a Slack channel, and an agent answers there in threads.

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
```

Each Slack workspace is its own [channel](/channels/), with its own app.

## A Slack app

Give the daemon its own app; Slack splits button presses across every connection an app has.

1. At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App**, **From a
   manifest**, pick your workspace, and paste the manifest below. Change `Wardrik` to the name your
   team will see.
2. **Install to Workspace**, then copy the **Bot User OAuth Token** (`xoxb-...`) from **OAuth &
   Permissions**. This is `token`.
3. Under **Basic Information › App-Level Tokens**, make a token with the scope `connections:write`
   (`xapp-...`). This is `app_token`.

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
      - groups:history
      - groups:read
      - reactions:write
      - users:read
      - users:read.email
settings:
  event_subscriptions:
    bot_events:
      - channel_left
      - group_left
      - member_joined_channel
      - message.channels
      - message.groups
  interactivity:
    is_enabled: true
  org_deploy_enabled: false
  socket_mode_enabled: true
  token_rotation_enabled: false
```

Seal both tokens in the vault and restart the daemon:

```sh
wardrik vault put SLACK_BOT_TOKEN    # xoxb-...
wardrik vault put SLACK_APP_TOKEN    # xapp-...
systemctl --user restart wardrik
```

Invite the app into a Slack channel with `/invite @yourapp`. It always replies; if it doesn't, see
[The app says nothing](#the-app-says-nothing).

## An agent in a Slack channel

An agent is offered in Slack when its file lists the channel:

```yaml
# in an agent file
channels: [slack]
```

Invite the app, and it introduces the agent:

> :wave: **acme/books** answers here now.
> _Keeps the books: reconciles Square deposits and posts to QuickBooks._
> Mention @Wardrik and it answers in a thread under your message. A call that needs approval waits
> here for someone to approve it.
> `[Answer every message]` `[⋯]`

**Answer every message** makes the channel the agent's own; ⋯ switches agents or stops it. With
approvers named, the last line names them. For several agents or none, see
[Channels](/channels/#a-rooms-agent).

## Threads in Slack

Mention the app, and the agent answers in a thread under your message. Reply in the thread, and it
answers again without a mention.

> **maria:** @Wardrik how much Barolo is left? :eyes:
> ↳ **Wardrik:** Two cases, both 2019.

The app marks a message :eyes: when the agent takes it, and :white_check_mark: once it answers. See
[Channels](/channels/#threads) for how threads work.

## What a notice says in Slack

A waiting call shows its tool, the policy's question, its arguments, and whether the turn had read
outside content, with **Approve**, **Deny** and a box for a note. The message updates to say who
decided.

> Denied in Slack by jon: Deploy to staging first, and show me the diff.

A denial passes the note to the model as the reason. An approval runs the call as written, with the
note beside the result. A finished turn's answer is posted as Markdown.

## Who approves

`approvers` lists who may press the buttons, by `@handle`, email address or Slack member ID.
`approvers: anyone` lets everyone in the channel answer.

```yaml
channels:
  slack:
    type: slack
    approvers: ["@maria", "@jon"]   # these people; or: anyone
```

Each approver is asked in the app's messages, with a link, and the thread says who it waits on:

> ↳ **Wardrik:** Waiting on @maria or @jon to approve `create_bill`.

The first to answer decides, and the thread says who and what they wrote. Whoever asked for the turn
can always answer. Without approvers, only they can, and a trigger's turn is answered with
`wardrik approve` on the server; `wardrik doctor` says which a channel does.

## Details

### What the manifest asks for

- **Socket Mode and interactivity:** events arrive over a connection the daemon opens to Slack, so
  it needs no public address or open port.
- **Bot events:** `member_joined_channel`, `channel_left` and `group_left` report invites and
  removals; `message.channels` and `message.groups` carry posts.
- **Bot scopes:** read and post, mark messages, and find people by `@handle`. `users:read.email` is
  only needed for approvers named by email.
- **Messages Tab:** where approvers are asked. Direct messages to the app aren't answered.

No user scopes are needed; the app acts as itself. A new scope means installing the app again.

### The app says nothing

The daemon binds a channel when it hears the app arrive. If it was invited while the daemon was down,
or before events were on, `/remove @yourapp` and invite it again. Otherwise check the bot events
above, and the daemon's log for a Socket Mode error.

### Messages and accounts

- The agent reads each message as from its sender's Slack name and member ID. It skips edits,
  deletions, other bots, and people from another workspace.
- A call waiting for an account shows **Show link**, visible only to whoever pressed it. See
  [Connect accounts](/build/accounts/).
- Bindings are recorded with who made them, as `wardrik.room.bound` and `wardrik.room.unbound`
  [events](/reference/events/).

### Finding approvers

Approvers are found by `@handle`, email or member ID (**Copy member ID** in a Slack profile). One
that can't be found is still named in the thread and logged. If the app can message none of them, it
asks in the thread. `admins` and [notice target](/build/notices/) approvers may also answer.

### Without buttons

Without `app_token`, a parked notice says which `wardrik approve` or `wardrik deny` to run. The bot
token alone can post.
