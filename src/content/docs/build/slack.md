---
title: Slack
description: "Add an agent to a Slack channel. It replies in threads, and posts Approve and Deny buttons for calls that need approval."
---

Create a Slack app, map members to users, and invite the app to a channel. Slack is the only
channel type.

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    members: {U024BE7LH: user:default/@maria, U0G9QF9C6: user:default/@jon}
```

- `slack` is the channel's name: lower-case letters, digits and `-`. Every key is in
  [config.yaml › channels](/reference/config/#channels).
- Slack sends events over HTTPS to `/v1/channels/slack/`, so the daemon needs a
  [public address](/run/public-address/). To test without one, use [Socket Mode](#testing-with-socket-mode).

## A Slack app

1. At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App › From a manifest**.
   Paste the manifest below. Change `agents.example.com` to the daemon's address.
2. Choose **Install to Workspace**. Copy the **Bot User OAuth Token** (`xoxb-...`).
3. Under **Basic Information › App Credentials**, copy the **Signing Secret**.

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

- `slack` in each URL is the channel's name in `config.yaml`.
- Slack verifies the events URL on save, so the daemon must be reachable first.

Store both secrets, then restart the daemon:

```sh
echo "xoxb-..." | wardrik vault put SLACK_BOT_TOKEN --for api_key
echo "..." | wardrik vault put SLACK_SIGNING_SECRET --for signing_secret
wardrik stop && wardrik start
```

Copy each member ID from the Slack profile (**Copy member ID**) into `members`.

### Testing with Socket Mode

Socket Mode needs no public address. It's for testing.

1. In the manifest, set `socket_mode_enabled: true` and remove both `request_url` lines.
2. Under **Basic Information › App-Level Tokens**, create a token with `connections:write` (`xapp-...`).
3. Set `app_token` instead of `signing_secret`:

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
```

Use a separate app per daemon. Slack distributes events across all of an app's connections.

## Members

`members` maps each Slack member ID to a daemon user. A member acts as that user, with that user's
bindings. What members can do is in [built-in rules](/run/orgs/#built-in-rules).

- An unmapped member is refused, with a message to ask an admin.
- `unmapped_members: allow` maps them to `user:slack:T0123/U024BE7LH`. For small deployments.

## Add an agent to a channel

List the channel in the agent's file, then `/invite @Wardrik` in Slack:

```yaml
channels: [slack]
```

> :wave: **books** answers here now.
> `[Answer every message]` `[⋯]`

- With one agent available, it replies when mentioned. **Answer every message** makes it reply to
  each message, in its own thread.
- With several, the bot posts a button per agent. With none, it posts how to make one available.
- **⋯** has **Use another agent** and **Stop answering here**. Removing the bot also unbinds the
  channel.
- A channel is available to the deployment's org, unless [`orgs`](/reference/config/#orgs)
  assigns it to another.

## Threads

> **maria:** @Wardrik how much Barolo is left? :eyes:
> ↳ **Wardrik:** Two cases, both 2019.

- Mention the bot to start a thread. Replies in the thread need no mention.
- Each thread is a conversation, such as `conversation: "slack.T0123.C024BE91L.1696.1234"`. Threads
  share the agent's definition and [files](/concepts/files-and-memory/).
- :eyes: means the agent received the message. :white_check_mark: means it replied.
- The thread's status shows the agent's current activity.
- To post notices in a channel, set `notify: "slack:#updates"`. See [Send notices](/build/notices/).

## Approval messages

A pending call shows its tool, the policy message and its arguments, with **Approve**, **Deny**
and a note field. Once resolved, the buttons are replaced with the result:

> Denied `deploy` by @jon: Deploy to staging first, and show me the diff.

## Who approves

The member who started the turn can always approve its calls. Anyone else needs a binding (see
[Who can approve](/concepts/approvals/#who-can-approve)):

```yaml title="~/.config/wardrik/config.yaml"
roles:
  approver: {rules: [{verbs: [approve, deny, decide], kinds: [agent], names: [books]}]}
bindings:
  - {org: default, role: approver, subjects: [user:default/@maria]}
```

A triggered turn has no member who started it. Use `wardrik approval approve`.

## The app doesn't reply

If the app was invited while the daemon was down, `/remove @Wardrik` and invite it again. Then
check:

- **Event Subscriptions** shows the request URL as verified;
- `wardrik doctor` verifies the tokens with Slack;
- `wardrik logs`.
