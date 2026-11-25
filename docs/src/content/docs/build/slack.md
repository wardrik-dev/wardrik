---
title: Slack
description: "Add an agent to a Slack channel. It replies in threads, and posts Approve and Deny buttons for calls that need approval."
---

Use agents in Slack threads and review tool calls with **Approve** and **Deny** buttons.
For HTTP delivery, the daemon needs a [public HTTPS address](/run/public-address/).
For local testing, use [Socket Mode](#testing-with-socket-mode).

## Set up

1. At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App › From a
   manifest**. Paste the manifest below, with `agents.example.com` changed to the daemon's
   address. Slack will verify the URL after you start the configured daemon in step 6.
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
    messages_tab_read_only_enabled: false
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
      - im:history
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
      - message.im
      - tokens_revoked
  interactivity:
    is_enabled: true
    request_url: https://agents.example.com/v1/channels/slack/actions
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

- `slack` in each URL is the channel's name in `config.yaml`: lower-case letters, digits and `-`.
- See all settings in [config.yaml › channels](/reference/config/#channels).

## Members

Map Slack members to Wardrik users to control access. Each member uses the mapped user’s
permissions. See [built-in rules](/run/orgs/#built-in-rules).

- `domains` maps an email domain to an org. `maria@acme.com` acts as `user:acme/@maria`.
- `members` maps one member ID to a user, and wins over `domains`. Copy the ID from the member's
  Slack profile (**Copy member ID**):

  ```yaml
  members: {U024BE7LH: user:admin}
  ```

- Unmapped members receive an access-denied message directing them to an admin.
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
- Every channel an agent answers in shares its files and digests. To keep a private channel's
  work out of a public one, give each its own agent.
- :eyes: means the agent received the message. :white_check_mark: means it replied.
- While the agent works, one message in the thread lists its steps: each model call, with its
  reasoning under it, each tool call, and each retry with its wait. A step that runs quietly shows
  how long it has run. The reply follows that message.
- Set `reasoning: false` on the channel to leave the reasoning out.
- Slack ends a streamed message after 10 minutes. A longer run, or one started by a trigger or
  notice, lists its steps in a message it edits instead.
- To post notices in a channel, set `notify: "slack:#updates"`. See [Send notifications](/build/notices/).

## Direct messages

Name the agent that answers direct messages to the app:

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
    domains: {acme.com: acme}
    direct: assistant
```

- The agent must list the channel in its file, as `channels: [slack]`.
- It answers every direct message in a thread of its own, without a mention. Replies in the
  thread continue that conversation.
- A reply under a notice goes to this agent too, with the notice quoted. Ask it to change the
  agent the notice is about, such as how often it runs.
- It runs as the member who sent the message, and only they can approve its calls.
- Each member's threads are their own conversations, but they share the agent's files and
  digests, as rooms do.
- The app needs the `im:history` scope and the `message.im` event, as in the manifest above. An app
  made from an older manifest needs both added, and installing again.

### An agent per member

Give each member an agent of their own, made from the one `direct` names:

```yaml
    direct: {agent: assistant, per: member}
```

- On Ana's first direct message, the daemon makes `assistant.ana`, owned by her. Her next messages
  go to it.
- It has `assistant`'s instructions, tools and policy, but not its triggers or notices. Its files
  and digests are hers alone.
- `wardrik reload` defines every member's agent again from `assistant.md`, so a change to the file,
  as a tool taken away, reaches them all.
- If `assistant.md` is removed, members' agents keep their last definition.
- To start a member over, forget their agent. Their next message makes a new one.
- A member who isn't a person, as `user:admin`, is answered by `assistant` itself.

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

Scheduled and webhook-triggered turns have no initiating Slack member. Use a CLI admin approval
or grant an approver role to the Slack users who should review them.

## The app doesn't reply

If the app was invited while the daemon was down, `/remove @Wardrik` and invite it again. Then
check:

- **Event Subscriptions** has **Enable Events** on, and shows the request URL as verified;
- the request URLs under **Event Subscriptions** and **Interactivity & Shortcuts** are the
  daemon's, not `agents.example.com`, and each page's changes are saved;
- `wardrik doctor` verifies the tokens with Slack;
- `wardrik logs`.

If a member is denied access, check their Slack email domain or add their member ID to `members`.
