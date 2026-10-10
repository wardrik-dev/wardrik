---
title: Slack
description: A Slack app of Wardrik's own, invited into a Slack channel to have an agent answer there in threads, and to post notices with Approve and Deny buttons.
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

1. At [api.slack.com/apps](https://api.slack.com/apps), **Create New App**, **From a manifest**,
   choose your workspace, and give it the manifest below, with the name your team will see in
   place of `Wardrik`.
2. **Install to Workspace**, and copy the **Bot User OAuth Token**, `xoxb-...`, from **OAuth &
   Permissions**. This is the channel's `token`.
3. Under **Basic Information**, in **App-Level Tokens**, make a token with the scope
   `connections:write`, `xapp-...`. This is the channel's `app_token`.

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

What it asks for, and why:

- **Socket Mode and interactivity**, so messages and button presses come over a connection the
  daemon opens, with no request URL.
- **The bot events** `member_joined_channel`, `channel_left` and `group_left`, so the daemon hears
  when the app is invited into a Slack channel or taken out of one, and `message.channels` and
  `message.groups`, so it hears what is posted there.
- **The bot scopes** to read those channels and post in them, to mark a message it answers, and to
  find people by `@handle`, or by email address with `users:read.email`, which a channel whose
  [approvers](#who-approves) are named by email needs and any other may leave out.
- **The Messages Tab**, where the app asks a channel's approvers what a thread waits on. People
  cannot write to the app there, since direct messages to it are not answered.

The app needs no user token scopes: it acts as itself, never as whoever installed it. An app
changed to take a scope after it was installed is installed again to have it.

Seal both tokens in the vault, and restart the daemon, which reads `config.yaml` as it starts:

```sh
wardrik vault put SLACK_BOT_TOKEN    # xoxb-...
wardrik vault put SLACK_APP_TOKEN    # xapp-...
systemctl --user restart wardrik
```

Then, with the daemon running, invite the app to a Slack channel: `/invite @yourapp`. The daemon
binds the channel as it hears the app arrive, so an app invited while the daemon was not running,
or before Event Subscriptions were on, is there without an agent: take it out with
`/remove @yourapp` and invite it again.

The app always says something when it is invited: that an agent answers there, which agents to
choose among, or why none does. If it says nothing, the daemon did not hear the invitation: check
that events are on, with the bot events above, and that the daemon's log shows no Socket Mode error.

Messages and buttons arrive over Socket Mode, a connection the daemon opens out to Slack, so it
needs no public address and no open port.

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

Where the channel names [approvers](#who-approves), the last line says who they are instead.
> `[Answer every message]` `[⋯]`

**Answer every message** makes the Slack channel the agent's own; the ⋯ menu uses another agent, or
stops it answering there. Where several agents are offered, the app lists each with what it is for,
and a **Use** button. Where none is, it offers to **Create an agent for #books**, from the
deployment's defaults; see [Channels](/channels/#a-rooms-agent). Taking the app out of the Slack
channel unbinds it.

## Threads in Slack

Mention the app and the agent answers in a thread under your message; reply in the thread and it
answers again, without a mention. Where it answers every message, each message posted in the Slack
channel starts a thread. See [Channels](/channels/#threads) for how a thread is a conversation.

> **maria:** @Wardrik how much Barolo is left? :eyes:
> ↳ **Wardrik:** Two cases, both 2019.

The app marks each message the agent was asked with :eyes:, and changes it to :white_check_mark:
once the agent has answered. A call the agent may not make alone is asked with **Approve** and
**Deny**: of the channel's [approvers](#who-approves), each in the app's messages with them, where
the channel names any, and in the thread, of anyone there, where it names none. A call waiting on an
account to be connected has **Show link** instead, and the thread says "Connected github." once
someone has. A turn that fails says why there. A message the agent could not be asked gets a reply
saying why.

The agent reads each message as from whoever posted it, by the name Slack shows for them and their
member ID. It passes over edits, deletions, other bots, and anyone from another workspace in a Slack
channel shared with one; direct messages to the app are not answered.

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

Above each call's buttons is a box for a note to the agent, sent with either button. A call denied
from Slack tells the model "Denied in Slack by" whoever pressed it, and what they wrote there, as
`wardrik deny` passes on a reason:

> Denied in Slack by jon: Deploy to staging first, and show me the diff.

A call approved with a note runs, and the model reads the note beside its answer, as
`wardrik approve` passes one on. A note cannot change the call, which runs with the arguments the
model wrote; to change it, deny it and say what to do instead.

A call waiting on an account to be connected has **Show link** instead of Approve, which shows the
authorization link to whoever pressed it, and nobody else. See
[Connect accounts](/guides/accounts/).

**Finished:** what the agent answered, as the Markdown it wrote, which Slack renders.

## Who approves

A channel's `approvers` lists who may press the buttons, each by `@handle`, email address or Slack
user ID, and anyone else is told only the channel's approvers can answer. Without `approvers`,
anyone in the channel may. An email address needs the bot token scope `users:read.email`. A
member's ID is under **Copy member ID** in their Slack profile.

Where a channel names approvers, what a thread's agent waits on is sent to each of them in the
app's messages with them, under the app in Slack's sidebar, with a link to the thread, and the
thread says who it waits on:

> ↳ **Wardrik:** Waiting on @maria or @jon to approve `create_bill`.

The first to answer decides; anyone pressing after is told it was already answered. The thread
says who decided, and what they wrote, "Approved by maria: Only this once." or "Denied in Slack by jon: Staging first.", wherever they did, in
Slack or with `wardrik approve`, and then what the agent answers. A message that waits behind the question sends it to
them again.

The app finds each approver as a member of the workspace: a `@handle` among its members, an email
address by the address, a user ID as it is. One it cannot find is still named in the thread, and the
daemon's log says so. Where it can message none of them, as when the **Messages Tab** is off, it asks
in the thread instead.

A [notice target](/guides/notices/)'s `approvers` answer in the room it posts in.

## Without buttons

Without the channel's `app_token`, a parked notice says which `wardrik approve` or `wardrik deny` to run instead.
The bot token alone is enough to post.
