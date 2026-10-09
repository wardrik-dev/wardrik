---
title: Channels
description: The chat media agents are reached through, such as Slack. A channel is configured once, a room in it is bound to an agent by inviting its bot, the agent answers each conversation in a thread, and notices are posted in a room.
sidebar:
  order: 1
---

A *channel* is a chat medium Wardrik's agents are reached through, configured once under a name of
your own: one Slack workspace's app, say. A *room* is a place in it, such as a Slack channel.

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
```

`type` is which kind of channel it is; the rest of its settings are that kind's own. The kinds a
release holds:

| Type | |
| --- | --- |
| `slack` | [Slack](/channels/slack/), through a Slack app of Wardrik's own |

## Which agents a channel offers

An agent is offered in a channel where its file names the channel:

```yaml
# in an agent file
channels: [slack]
```

A channel offers the agents of the deployment's [org](/concepts/agents/#keys-and-orgs) unless its
`org` names others, or `*` for every org's:

```yaml
channels:
  globex-slack: {type: slack, org: globex, token: "${GLOBEX_SLACK_BOT_TOKEN}"}
```

## A room's agent

Inviting a channel's bot into a room gives the room an agent, and the bot always says where things
stand:

- **One agent offered:** it answers there at once, when mentioned. The bot says what the agent is
  for, from its `description`, and how to reach it, with a button to have it answer every message
  instead, which makes the room the agent's own, and a menu to use another agent or stop.
- **Several offered:** each with what it is for, and a button to use it.
- **None offered:** a button to create one for the room, from `config.yaml`'s `defaults`, where
  they name a policy. It is named after the room, offered in the channel, and kept as an agent the
  [HTTP API](/guides/http-api/) defined is, so whoever runs Wardrik can change it later. A channel's
  `create: false` turns this off; the bot then says who can offer an agent.

Taking the bot out of the room unbinds it. Each binding, each change to it, and each agent created
is recorded in the audit log, as `wardrik.room.bound`, `wardrik.room.unbound` and
`wardrik.agent.defined` [events](/reference/events/), with who made it.

## Threads

The room's agent answers in threads. A message posted in the room starts a thread of its own where
it mentions the bot, or where the agent answers every message; a reply in that thread reaches the
agent without a mention. Each thread is a conversation of its own: the agent reads what was said in
the thread, and not what was said in another, though its [files and memory](/concepts/files-and-memory/)
are shared among them all. Every thread runs on the agent's one definition, and every message the
agent reads names who sent it.

What the agent answers is posted in the thread, and so is anything it asks before a call its
[policy](/concepts/policy/) holds for a person, with buttons to answer it. A call waiting on
someone to [connect an account](/guides/accounts/) says so once they have, and carries on. A turn
that fails says why there. Replies are taken from the agent's [event log](/concepts/events/), so one held up by a
restart, or refused by the channel for a while, is posted when the daemon can.

While the agent waits on a person, a new message in the thread waits behind the question, and the
question is posted again, so the thread never goes quiet.

A channel's `approvers` may answer what an agent asks in its threads, each as the channel names
people, and are asked it directly, where the channel can reach a person, with the thread saying who
it waits on; without them, anyone in the room may, in the thread:

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
    approvers: ["@maria", "finance-lead@example.com"]
```

## Notices in a room

A [notice target](/guides/notices/) can be a room of a channel, with who may answer what it asks:

```yaml
notify:
  ops:
    channel: slack
    room: "#ops"
    approvers: ["@maria"]
```

## More kinds of channel

A kind of channel is a package of its own, which names itself in its application's environment, as
`wardrik_slack` names `type: slack`. A release that holds the package reads its channels from
`config.yaml`; nothing else changes. See `WardrikChannel` for what one implements.
