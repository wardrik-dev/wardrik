---
title: Channels
description: "Chat apps people reach agents through, such as Slack: invite the bot into a room, and an agent answers there in threads."
sidebar:
  order: 1
  label: Overview
---

A *channel* is a chat app your agents are reached through, such as a Slack app in your workspace.
A *room* is a place in it, such as a Slack channel. Invite the bot into a room, and an agent
answers there.

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
```

- **`slack`** is the channel's name, of your choosing: lower-case letters, digits and `-`.
- **`type`** is the kind of chat app. Today that's [Slack](/channels/slack/).
- **`token`** is what the bot acts with in your workspace.

The chat app sends to the daemon at `/v1/channels/slack/`, so the daemon needs a
[public address](/run/public-address/). Every key is in
[config.yaml › channels](/reference/config/#channels).

## Which agents a channel offers

An agent is offered in a channel when its file lists it:

```yaml
# in an agent file
channels: [slack]
```

A channel offers your deployment's own [org](/concepts/agents/#keys-and-orgs)'s agents, not its
users' agents. To give a channel to another org, list it under that org in `orgs`, or under `"*"`
for every org:

```yaml
channels:
  globex-slack: {type: slack, token: "${GLOBEX_SLACK_BOT_TOKEN}", signing_secret: "${GLOBEX_SLACK_SIGNING_SECRET}"}

orgs:
  globex:
    channels: [globex-slack]
```

A channel serves one org, or every org under `"*"`.

## A room's agent

Invite the bot, and it says what happens next:

- **One agent offered:** it answers there now, when mentioned. A button makes it answer every
  message.
- **Several:** a button to use each.
- **None:** it says how to offer one, with a button to look again.

Remove the bot to unbind the room.

## Threads

Mention the bot to start a thread. Replies in it reach the agent without a mention.

Each thread is its own conversation, with an ID of its own under the agent's, as
`acme/triage/slack.T0123.C024BE91L.1696.1234`. Every thread runs on the agent's one definition,
and shares its [files and memory](/concepts/files-and-memory/). Calls the
[policy](/concepts/policy/) holds are asked in the thread, with buttons.

## Who may answer

| Who | May decide |
| --- | --- |
| `approvers` | what any of the channel's agents wait on |
| `approvers: anyone` | everyone in the workspace may decide |
| whoever asked for the turn | what their own thread waits on, always |

A trigger's turn has nobody who asked. Without approvers, decide it from a shell with
`wardrik approval approve`. See [Who approves](/channels/slack/#who-approves).

An agent's `notify` can post into a room too, as `slack:#updates`. See
[Post in a room](/build/notices/#post-in-a-room).

## Details

- **Who can message an agent:** everyone in the workspace can message the agents the channel
  offers.
- **Every message** names who sent it, as the chat app knows them.
- **Replies survive restarts.** They come from the conversation's [event log](/concepts/events/),
  so one delayed by a restart is posted when the daemon can. A waiting question is posted again
  when a new message arrives behind it.
- **Audit:** bindings are recorded with who made them, as `wardrik.room.bound` and
  `wardrik.room.unbound` [events](/reference/events/). `wardrik audit` lists them.
- **New kinds of channel** are Elixir packages that `use WardrikChannel`, as `wardrik_slack` does.
  The daemon's `type` takes `slack`.
