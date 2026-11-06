---
title: Slack
description: "Add an agent to a Slack channel. It replies in threads, and posts Approve and Deny buttons for calls that need approval."
---

Slack sends events over HTTPS, so the daemon needs a [public address](/run/public-address/). To
test without one, use [Socket Mode](#testing-with-socket-mode).

## Set up

1. At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App › From a
   manifest**. Paste the manifest below, with `agents.example.com` changed to the daemon's
   address. Slack can't verify the URL yet; that's fixed in step 6.
2. Choose **Install to Workspace**, then copy the **Bot User OAuth Token** (`xoxb-...`). Under
   **Basic Information › App Credentials**, copy the **Signing Secret**.
3. Store both:

   ```sh
   echo "xoxb-..." | wardrik vault put SLACK_BOT_TOKEN --for api_key
   echo "..." | wardrik vault put SLACK_SIGNING_SECRET --for signing_secret
   ```

4. Add the channel to `config.yaml`. Change `acme.com` to your email domain, and `acme` to your
   org:

   ```yaml title="~/.config/wardrik/config.yaml"
   channels:
     slack:
       type: slack
       token: ${SLACK_BOT_TOKEN}
       signing_secret: ${SLACK_SIGNING_SECRET}
       domains: {acme.com: acme}
   ```

5. Restart the daemon, and check the channel:

   ```sh
   wardrik stop && wardrik start
   wardrik doctor
   ```

6. In the app's **Event Subscriptions**, choose **Retry** next to the request URL.
7. List the channel in the agent's file:

   ```yaml
   channels: [slack]
   ```

8. In a Slack channel, run `/invite @Wardrik`.

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

- `slack` in each URL is the channel's name in `config.yaml`: lower-case letters, digits and `-`.
- Every key is in [config.yaml › channels](/reference/config/#channels).

## Members

A Slack member acts as a daemon user, with that user's bindings. What they can do is in
[built-in rules](/run/orgs/#built-in-rules).

- `domains` maps an email domain to an org. `maria@acme.com` acts as `user:acme/@maria`.
- `members` maps one member ID to a user, and wins over `domains`. Copy the ID from the member's
  Slack profile (**Copy member ID**):

  ```yaml
  members: {U024BE7LH: user:admin}
  ```

- Anyone else is refused, and told to ask an admin.
- Members of other workspaces, over Slack Connect, are matched by `members` only.

## Testing with Socket Mode

Socket Mode needs no public address. It's for testing.

1. In the manifest, set `socket_mode_enabled: true` and remove both `request_url` lines.
2. Under **Basic Information › App-Level Tokens**, create a token with `connections:write`
   (`xapp-...`). Store it as `SLACK_APP_TOKEN`.
3. In `config.yaml`, set `app_token` in place of `signing_secret`:

   ```yaml
   channels:
     slack:
       type: slack
       token: ${SLACK_BOT_TOKEN}
       app_token: ${SLACK_APP_TOKEN}
       domains: {acme.com: acme}
   ```

Use a separate app per daemon. Slack spreads events across all of an app's connections.

## In a channel

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

## Approvals

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
  - {org: acme, role: approver, subjects: [user:acme/@maria]}
```

A triggered turn has no member who started it. Use `wardrik approval approve`.

## The app doesn't reply

If the app was invited while the daemon was down, `/remove @Wardrik` and invite it again. Then
check:

- **Event Subscriptions** shows the request URL as verified;
- `wardrik doctor` verifies the tokens with Slack;
- `wardrik logs`.

A member who is refused isn't mapped: check their Slack email address, or add them to `members`.
