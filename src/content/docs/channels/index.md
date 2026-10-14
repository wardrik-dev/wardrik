---
title: Channels
description: "Chat apps people reach agents through, such as Slack: invite the bot into a room, and an agent answers there in threads."
sidebar:
  order: 1
  label: Overview
---

A *channel* is a chat app your agents are reached through, such as one Slack workspace. A *room* is a
place in it, such as a Slack channel. Invite the bot into a room, and an agent answers there.

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
```

The name, `slack`, is yours. `type` is the kind of channel; today that's [Slack](/channels/slack/).
Every key is in [config.yaml › channels](/reference/config/#channels).

## Which agents a channel offers

An agent is offered in a channel when its file lists it:

```yaml
# in an agent file
channels: [slack]
```

A channel offers your deployment's [org](/concepts/agents/#keys-and-orgs), unless its `org` names
others, or `*` for all:

```yaml
channels:
  globex-slack: {type: slack, org: globex, token: "${GLOBEX_SLACK_BOT_TOKEN}"}
```

## A room's agent

Invite the bot, and it says what happens next:

- **One agent offered:** it answers when mentioned. A button makes it answer every message.
- **Several:** a button to use each.
- **None:** a button to create one from `config.yaml`'s `defaults`, when they name a policy.
  `create: false` turns this off.

Remove the bot to unbind the room.

## Threads

Mention the bot to start a thread; replies in it reach the agent without a mention. Each thread is
its own conversation, but [files and memory](/concepts/files-and-memory/) are shared across all of
them. Calls the [policy](/concepts/policy/) holds are asked in the thread, with buttons.

## Who may answer

`approvers` may answer what an agent waits on; `approvers: anyone` lets everyone. `admins` may also
answer, and change the org's agents where `defaults` names a policy, which holds what they define.
Whoever asked for a turn can always answer. Without approvers,
only they can, and a trigger's turn is answered from a shell. See
[Who approves](/channels/slack/#who-approves).

A [notice target](/build/notices/) can post into a room too, with its own approvers.

## Details

- **Who can message an agent:** everyone in a channel can message the agents of the orgs it offers,
  but not their users' agents. Others get a reply saying so.
- **Every thread** runs on the agent's one definition, and every message names who sent it.
- **Replies survive restarts:** they come from the agent's [event log](/concepts/events/), so one
  delayed by a restart is posted when the daemon can. A waiting question is posted again if a new
  message arrives behind it.
- **Created agents** are named after the room and kept like an [HTTP API](/build/http-api/)
  definition, so you can change them later.
- **Audit:** bindings and created agents are recorded with who made them, as `wardrik.room.bound`,
  `wardrik.room.unbound` and `wardrik.agent.defined` [events](/reference/events/).
- **New kinds of channel** are packages that name themselves in their application's environment, as
  `wardrik_slack` names `type: slack`.
