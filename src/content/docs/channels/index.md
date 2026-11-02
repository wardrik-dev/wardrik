---
title: Channels
description: "Chat apps people reach agents through, such as Slack. Invite the bot into a room, and an agent answers there in threads."
sidebar:
  order: 1
  label: Overview
---

A channel is a chat app your agents answer in, such as Slack. Invite the bot into a room, and an
agent answers there.

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    members: {U024BE7LH: user:default/@ana, U0G9QF9C6: user:default/@jon}
```

```yaml
# in an agent file
channels: [slack]
```

- `slack` is the channel's name: lower-case letters, digits and `-`.
- `type` is the chat app. Today that's [Slack](/channels/slack/).
- The app sends to `/v1/channels/slack/`, so the daemon needs a [public address](/run/public-address/).
- Every key is in [config.yaml › channels](/reference/config/#channels).

## Who each member is

`members` maps each chat member ID to a daemon user. A member acts as that user, so the user's
bindings decide what they may ask and decide.

- An unmapped member is refused, and told to ask an admin to map them.
- `unmapped_members: allow` lets them act as `user:slack:T0123/U024BE7LH`. For small deployments.
- Members can only ask, read and decide. Whoever asked for a turn may always decide its calls.

In Elixir, give the channel an `identities:` module. See `WardrikChannel.Identities`.

## Which agents a channel offers

An agent is offered where its file lists the channel. A channel serves the deployment's org,
unless `orgs` gives it to another:

```yaml
orgs:
  globex:
    channels: [globex-slack]
```

## A room's agent

Invite the bot, and it says what happens next:

- **One agent offered:** it answers when mentioned. A button makes it answer every message.
- **Several:** a button for each.
- **None:** it says how to offer one.

Remove the bot to unbind the room.

## Threads

Mention the bot to start a thread. Replies in it reach the agent without a mention.

- Each thread is a conversation of the agent, as `conversation: "slack.T0123.C024BE91L.1696.1234"`.
- Threads share the agent's definition and [files](/concepts/files-and-memory/).
- Calls the [policy](/concepts/policy/) holds are asked in the thread, with buttons.

## Notices in a room

An agent's `notify` can post in a room:

```yaml
notify: "slack:#updates"
```

It posts in the workspace the channel is added to for the agent's owner, else its org's. Never
another org's. See [Send notices](/build/notices/).
