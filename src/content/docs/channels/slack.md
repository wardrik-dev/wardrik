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
    signing_secret: ${SLACK_SIGNING_SECRET}
```

Slack sends the app's events to the daemon over HTTPS, so the daemon needs a
[public address](/run/public-address/). To try it without one, use
[Socket Mode](#testing-with-socket-mode).

## A Slack app

Give the daemon its own app.

1. At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App**, then **From a
   manifest**. Pick your workspace, and paste the manifest below. Change `Wardrik` to the name your
   team will see, and `agents.example.com` to the daemon's address.
2. Choose **Install to Workspace**. Copy the **Bot User OAuth Token** (`xoxb-...`) from **OAuth &
   Permissions**. This is `token`.
3. Under **Basic Information › App Credentials**, copy the **Signing Secret**. This is
   `signing_secret`.

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
      - users:read.email
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

`slack` in each URL is the channel's name in `config.yaml`. Slack checks the events URL as you save
the manifest, so the daemon must be running and reachable at that address first.

Seal both secrets in the vault, and restart the daemon:

```sh
echo "xoxb-..." | wardrik vault put SLACK_BOT_TOKEN
echo "..." | wardrik vault put SLACK_SIGNING_SECRET
wardrik stop && wardrik start
```

Invite the app into a Slack channel with `/invite @yourapp`. It always replies. If it doesn't, see
[The app says nothing](#the-app-says-nothing).

### Testing with Socket Mode

Slack's Socket Mode is for testing. Events arrive over a connection the daemon opens to Slack, so
it needs no public address.

1. In the manifest, set `socket_mode_enabled: true` and drop both `request_url` lines.
2. Under **Basic Information › App-Level Tokens**, make a token with the scope `connections:write`
   (`xapp-...`).
3. Name it `app_token`, in place of `signing_secret`:

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
```

Give each daemon its own app here. Slack spreads an app's Socket Mode events and button presses
across every connection it has.

## An agent in a Slack channel

An agent is offered in Slack when its file lists the channel:

```yaml
# in an agent file
channels: [slack]
```

Invite the app, and it introduces the agent:

> :wave: **books** answers here now.
> _Keeps the books: reconciles Square deposits and posts to QuickBooks._
> Mention @Wardrik, and it answers in a thread under your message. A call that needs approval
> waits in its thread for whoever asked.
> `[Answer every message]` `[⋯]`

- **Answer every message** has the agent answer each message in the channel, each in a thread of
  its own.
- **⋯** has **Use another agent** and **Stop answering here**.

With approvers named, the last line names them. For several agents or none, see
[Channels](/channels/#a-rooms-agent).

## Threads in Slack

Mention the app, and the agent answers in a thread under your message. Reply in the thread, and it
answers again without a mention.

> **maria:** @Wardrik how much Barolo is left? :eyes:
> ↳ **Wardrik:** Two cases, both 2019.

The app marks a message :eyes: when the agent takes it, and :white_check_mark: once it answers.
While the agent works, the thread's status shows what it's doing. Stopping the turn clears it. See
[Channels](/channels/#threads) for how threads work.

## What a notice says in Slack

A waiting call shows its tool, the policy's question and its arguments. It says so if the turn had
read content from outside. Below are **Approve**, **Deny** and a box for a note. Once someone
decides, the buttons give way to who decided:

> Denied `deploy` by @jon: Deploy to staging first, and show me the diff.

A denial passes the note to the model as the reason. An approval runs the call as written, with the
note beside the result. A finished turn's answer is posted as Markdown.

## Who approves

`approvers` lists who may press the buttons, by `@handle`, email address or Slack member ID.
`approvers: anyone` lets everyone answer.

```yaml
channels:
  slack:
    type: slack
    approvers: ["@maria", "@jon"]   # these people; or: anyone
```

1. Each approver is asked in the app's Messages tab, with a link to the thread.
2. The thread says who it waits on:

   > ↳ **Wardrik:** Waiting on @maria or @jon to approve `create_bill`.

3. The first to answer decides.

Whoever asked for the turn can always answer. Without approvers, only they can. A trigger's turn is
answered with `wardrik approval approve` on the server. `wardrik doctor` says who decides in each
channel.

## Details

### What the manifest asks for

- **Event Subscriptions and Interactivity:** Slack sends events to `/events` and button presses to
  `/actions`, under `/v1/channels/slack/`. Each is signed with the signing secret. The daemon
  refuses a request Slack didn't sign, or signed more than five minutes before.
- **Bot events:** `member_joined_channel`, `channel_left` and `group_left` report invites and
  removals. `message.channels` and `message.groups` carry posts. `app_uninstalled` and
  `tokens_revoked` say the app was taken out.
- **Bot scopes:** read and post, post in any public channel, mark messages, and find people by
  `@handle`. `users:read.email` is only needed for approvers named by email.
- **Notices in a room:** with `chat:write.public`, a [notice](/build/notices/#post-in-a-room)
  posts in any public channel without the bot invited. A private channel needs it invited.
- **Messages tab:** where approvers are asked.

No user scopes are needed; the app acts as itself. A new scope means installing the app again.

### The app says nothing

The daemon binds a channel when it hears the app arrive. If it was invited while the daemon was
down, or before events were on, `/remove @yourapp` and invite it again. Otherwise check:

- the bot events above;
- that **Event Subscriptions** shows the request URL verified;
- `wardrik doctor`, which checks the tokens with Slack;
- `wardrik logs`.

### Messages and accounts

- The agent reads each message as from its sender, as Slack names them. It skips other bots, and
  workspaces the app isn't added to.
- A call waiting for an account shows **Show link**. Its link goes only to whoever pressed it. See
  [Connect accounts](/build/accounts/).
- Bindings are recorded with who made them, as `wardrik.room.bound` and `wardrik.room.unbound`
  [events](/reference/events/).

### Finding approvers

Approvers are found by `@handle`, email or member ID (**Copy member ID** in a Slack profile). If
Slack reaches none of them, the call is asked in the thread instead.

### One app in many workspaces

The daemon runs one app in the one workspace its `token` reaches. An app
[embedded](/build/embed/#answer-in-slack) in your service can be added to many, one for each org.

1. Give the channel `client_id` and `client_secret`, from **Basic Information › App
   Credentials**, in place of `token`, with `installations: :stored`.
2. Set the app's **Redirect URL** to a route in your app, and pass it as `redirect_uri`.
3. Send someone acting for the org to `Wardrik.Channels.install_url/4`.
4. In your redirect route, hand Slack's query to `Wardrik.Channels.installed/4`.

Each workspace's token is sealed with Wardrik's `:keys`, and the workspace offers its org's agents
alone. `WardrikChannel`'s `:offering` and `:deciding` options put what the app says in your own
words.
