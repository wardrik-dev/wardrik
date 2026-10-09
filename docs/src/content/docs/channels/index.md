---
title: Channels
description: The chat media agents are reached through, such as Slack. A channel is configured once, a room in it is bound to an agent by inviting its bot, and notices are posted in a room.
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

Inviting a channel's bot into a room binds the room to an agent: the one the channel offers, or the
one chosen among several. It answers there when mentioned, or to every message, which makes the
room the agent's own. Taking the bot out of the room unbinds it. Each binding, and each change to
it, is recorded in the audit log as `wardrik.room.bound` and `wardrik.room.unbound`
[events](/reference/events/), with who made it.

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
