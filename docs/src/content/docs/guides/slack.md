---
title: Approve calls from Slack
description: Have agents tell a Slack channel when they wait on a person, fail or answer, with Approve and Deny buttons, or send the same notices to a signed webhook.
sidebar:
  order: 4
---

An agent nobody is watching can tell someone when it parks on a question, fails, or answers.
`config.yaml` names the targets under `notify`, and each agent file routes its notices to them:

```yaml title="~/.config/wardrik/config.yaml"
notify:
  ops:
    slack:
      channel: "#ops"
      token: ${SLACK_BOT_TOKEN}
      app_token: ${SLACK_APP_TOKEN}
      approvers: [U012ABCDEF]
  audit:
    webhook:
      url: https://hooks.example.com/wardrik
      secret: ${WARDRIK_WEBHOOK_SECRET}
```

```yaml
# in an agent file
notify: ops                                         # parked and failed turns, to ops
notify: [ops, audit]
notify: {to: [ops], on: [parked, failed, finished]}
```

`on` is what is sent: `parked`, `failed`, and `finished` for what a turn answered. It is
`[parked, failed]` unless set. A notice is sent once, from the node holding the agent.

## A Slack app

Give the daemon a Slack app of its own. Slack shares an app's button presses among every connection
the app has, so another service connected with the same app would receive some of them.

1. Create an app at [api.slack.com/apps](https://api.slack.com/apps), from scratch, in your
   workspace.
2. Under **OAuth & Permissions**, add the bot token scope `chat:write`, install the app, and copy the
   **Bot User OAuth Token**, `xoxb-...`. This is `token`.
3. Under **Socket Mode**, turn it on, and make an app-level token with the scope
   `connections:write`, `xapp-...`. This is `app_token`.
4. Under **Interactivity & Shortcuts**, turn interactivity on. Socket Mode needs no request URL.
5. Invite the app to the channel: `/invite @yourapp`.

Seal both tokens in the vault, and restart the daemon, which reads `config.yaml` as it starts:

```sh
wardrik vault put SLACK_BOT_TOKEN    # xoxb-...
wardrik vault put SLACK_APP_TOKEN    # xapp-...
systemctl --user restart wardrik
```

The buttons arrive over Socket Mode, a connection the daemon opens out to Slack, so it needs no
public address and no open port.

## What a notice says

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

**Failed:** why the turn failed. **Finished:** what the turn answered, which suits an agent on a
[schedule](/guides/schedules/).

A turn waiting on several calls sends a notice again when some are decided and others still wait.

## Which orgs a target tells

A target tells the agents of the deployment's [org](/concepts/agents/#keys-and-orgs) unless its
`org` names others, or `*` for every org:

```yaml
notify:
  ops:
    slack: {channel: "#ops", token: "${SLACK_BOT_TOKEN}"}
  globex-ops:
    org: globex
    slack: {channel: "#globex-ops", token: "${GLOBEX_SLACK_BOT_TOKEN}"}
```

An agent file that routes to another org's target does not read, so one org's calls never reach
another's channel, where its people could approve them.

## Who may press the buttons

`approvers` lists the Slack user IDs that may, and anyone else is told only the channel's approvers
can answer. Without `approvers`, anyone in the channel may. A member's ID is under **Copy member
ID** in their Slack profile.

## Without buttons

Without `app_token`, a parked notice says which `wardrik approve` or `wardrik deny` to run instead.
The bot token alone is enough to post.

## Webhooks

A `webhook` target is sent each notice as JSON, in a POST:

```json
{
  "event": "turn_parked",
  "agent": "acme/triage",
  "at": "2026-10-01T12:04:09.611Z",
  "calls": [
    {
      "id": "call_1",
      "name": "github__create_issue",
      "arguments": {"title": "Disk full on db-2"},
      "prompt": "This opens an issue on GitHub.",
      "authorization": false,
      "outside_content": true
    }
  ],
  "reason": null,
  "text": null
}
```

`event` is `turn_parked`, `turn_failed` or `turn_finished`, and is in the `x-wardrik-event` header
too. `reason` is why a turn failed, and `text` what it answered. A call's `outside_content` says
whether its turn had read content from outside first, which may be what asked for it.

With a `secret`, each body is signed, as `x-wardrik-signature: sha256=<hex>`: the HMAC-SHA256 of the
raw body, keyed with the secret. Check it against the body as it arrived, before parsing it:

```js
import { createHmac, timingSafeEqual } from "node:crypto";

const expected = "sha256=" + createHmac("sha256", secret).update(rawBody).digest("hex");
const ok =
  signature.length === expected.length &&
  timingSafeEqual(Buffer.from(expected), Buffer.from(signature));
```

The signature covers the body only, with no time in it, so a body sent again verifies again. Use
`at` to refuse old ones if that matters to you.

An answer other than 2xx is a failure. A failure that may pass is tried up to three more times, and
each try waits up to 10 seconds for an answer. A notice that still fails is logged and dropped.
