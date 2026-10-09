---
title: Slack
description: A Slack app of Wardrik's own, invited into a Slack channel to have an agent answer there, and to post notices with Approve and Deny buttons.
sidebar:
  order: 2
---

Slack is a [channel](/channels/), `type: slack`: one Slack app of Wardrik's own, in one workspace.
`config.yaml` names it under `channels`, with the app's tokens:

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
```

Each Slack workspace is a channel of its own, with an app of its own.

## A Slack app

Give the daemon a Slack app of its own. Slack shares an app's button presses among every connection
the app has, so another service connected with the same app would receive some of them.

1. Create an app at [api.slack.com/apps](https://api.slack.com/apps), from scratch, in your
   workspace.
2. Under **OAuth & Permissions**, add the bot token scopes `chat:write`, `channels:read` and
   `groups:read`, install the app, and copy the **Bot User OAuth Token**, `xoxb-...`. This is the
   channel's `token`.
3. Under **Socket Mode**, turn it on, and make an app-level token with the scope
   `connections:write`, `xapp-...`. This is the channel's `app_token`.
4. Under **Interactivity & Shortcuts**, turn interactivity on. Socket Mode needs no request URL.
5. Under **Event Subscriptions**, turn events on and subscribe to the bot events
   `member_joined_channel`, `channel_left` and `group_left`, so the daemon hears when the app is
   invited into a Slack channel or taken out of one.
6. Invite the app to the channel: `/invite @yourapp`.

Seal both tokens in the vault, and restart the daemon, which reads `config.yaml` as it starts:

```sh
wardrik vault put SLACK_BOT_TOKEN    # xoxb-...
wardrik vault put SLACK_APP_TOKEN    # xapp-...
systemctl --user restart wardrik
```

The buttons arrive over Socket Mode, a connection the daemon opens out to Slack, so it needs no
public address and no open port.

## An agent in a Slack channel

An agent is offered in Slack where its file names the channel:

```yaml
# in an agent file
channels: [slack]
```

Inviting the app into a Slack channel then has an agent answer there, and the app says so:

> :wave: **acme/books** answers here now.
> _Keeps the books: reconciles Square deposits and posts to QuickBooks._
> Mention @Wardrik and it answers in a thread under your message. A call that needs approval waits
> here for someone to approve it.
> `[Answer every message]` `[⋯]`

**Answer every message** makes the Slack channel the agent's own; the ⋯ menu uses another agent, or
stops it answering there. Where several agents are offered, the app lists each with what it is for,
and a **Use** button. Where none is, it offers to **Create an agent for #books**, from the
deployment's defaults; see [Channels](/channels/#a-rooms-agent). Taking the app out of the Slack
channel unbinds it.

Each binding, and each change to when it answers, is recorded in the audit log, as
`wardrik.room.bound` and `wardrik.room.unbound` [events](/reference/events/), with
the Slack user who made it.

A channel offers the agents of the deployment's org unless its `org` names others; see
[Channels](/channels/#which-agents-a-channel-offers).

## What a notice says in Slack

**Parked:** which agent is waiting, and for each call its tool, what the policy asks, whether the
turn had read content from outside first, and its arguments, with **Approve** and **Deny** buttons.
Pressing one decides the call as `wardrik approve` or `wardrik deny` would, and the message is
changed to say who decided it and how.

Above each call's buttons is a box for why it is denied, or what to do instead. A call denied from
Slack tells the model "Denied in Slack by" whoever pressed it, and what they wrote there, as
`wardrik deny` passes on a reason, so a denial can steer the agent:

> Denied in Slack by jon: Deploy to staging first, and show me the diff.

Approving leaves the box unsaid.

A call waiting on an account to be connected has **Show link** instead of Approve, which shows the
authorization link to whoever pressed it, and nobody else. See
[Connect accounts](/guides/accounts/).

## Who may press the buttons

`approvers` lists who may, each by `@handle`, email address or Slack user ID, and anyone else is
told only the channel's approvers can answer. Without `approvers`, anyone in the channel may. An
email address needs the bot token scope `users:read.email`. A member's ID is under **Copy member
ID** in their Slack profile.

## Without buttons

Without the channel's `app_token`, a parked notice says which `wardrik approve` or `wardrik deny` to run instead.
The bot token alone is enough to post.
