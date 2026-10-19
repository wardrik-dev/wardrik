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

1. At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App**, **From a
   manifest**, pick your workspace, and paste the manifest below. Change `Wardrik` to the name your
   team will see, and `agents.example.com` to the daemon's address.
2. **Install to Workspace**, then copy the **Bot User OAuth Token** (`xoxb-...`) from **OAuth &
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

Seal both secrets in the vault and restart the daemon:

```sh
wardrik vault put SLACK_BOT_TOKEN        # xoxb-...
wardrik vault put SLACK_SIGNING_SECRET
systemctl --user restart wardrik
```

Invite the app into a Slack channel with `/invite @yourapp`. It always replies; if it doesn't, see
[The app says nothing](#the-app-says-nothing).

### Testing with Socket Mode

Slack's Socket Mode is for testing: events arrive over a connection the daemon opens to Slack, so it
needs no public address. In the manifest, set `socket_mode_enabled: true` and drop both
`request_url` lines. Under **Basic Information › App-Level Tokens**, make a token with the scope
`connections:write` (`xapp-...`), and name it `app_token` in place of `signing_secret`:

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
```

Give each daemon its own app here: Slack splits an app's Socket Mode events and button presses
across every connection it has.

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

The app marks a message :eyes: when the agent takes it, and :white_check_mark: once it answers.
While the agent works, the thread shows what it's doing, as *Wardrik is running web_search…*;
stopping the turn clears that and takes the :eyes: away. See [Channels](/channels/#threads) for how
threads work.

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

- **Event Subscriptions and Interactivity:** Slack sends events to `/events` and button presses to
  `/actions`, under `/v1/channels/slack/`, each signed with the signing secret. The daemon refuses
  any request Slack didn't sign, or signed more than five minutes before.
- **Bot events:** `member_joined_channel`, `channel_left` and `group_left` report invites and
  removals; `message.channels` and `message.groups` carry posts; `app_uninstalled` and
  `tokens_revoked` say the app was taken out.
- **Bot scopes:** read and post, mark messages, and find people by `@handle`. `users:read.email` is
  only needed for approvers named by email.
- **Messages Tab:** where approvers are asked. Direct messages to the app aren't answered.

No user scopes are needed; the app acts as itself. A new scope means installing the app again.

### The app says nothing

The daemon binds a channel when it hears the app arrive. If it was invited while the daemon was down,
or before events were on, `/remove @yourapp` and invite it again. Otherwise check the bot events
above, that **Event Subscriptions** shows the request URL verified, and the daemon's log.

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

Without `signing_secret` or `app_token`, a parked notice says which `wardrik approve` or
`wardrik deny` to run. The bot token alone can post.

### One app in many workspaces

The daemon runs one app in the one workspace its `token` reaches. An app [embedded](/build/embed/)
in your own service can be installed in many, one for each org: give the channel `client_id` and
`client_secret` from **Basic Information › App Credentials** in place of `token`, set the app's
**Redirect URL** to your install route, and send each org's admin to
`WardrikChannel.install_url/3`. Your route hands Slack's redirect to `WardrikChannel.install/3` for
the org they act for, and your `WardrikChannel.Installations` keeps each workspace's token.
