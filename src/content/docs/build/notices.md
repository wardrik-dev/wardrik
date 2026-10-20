---
title: Send notices
description: "Have agents tell people when they wait on a person, fail or answer, in a Slack room or at a signed webhook."
sidebar:
  order: 7
---

An agent nobody is watching can tell someone when it waits on a person, fails, or answers. Name the
targets in `config.yaml`, then route each agent's notices to them. A target is a room in one of
your [channels](/channels/), or a webhook:

```yaml title="~/.config/wardrik/config.yaml"
notify:
  ops:
    channel: slack
    room: "#ops"
    approvers: ["@maria", jon@example.com]
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

`on` is `parked`, `failed`, and `finished` for what a turn answered; `[parked, failed]` unless set.

## Post in a room

Name a room of a channel as `channel:room`, with no target in `config.yaml`:

```yaml
# in an agent file
notify: {to: ["slack:#updates"], on: [parked, failed, finished]}
```

It posts where the channel [offers the agent's org](/channels/#which-agents-a-channel-offers), in the
workspace the channel is installed in for that org, or for every org. An agent never posts in another
org's workspace. Where there is none, nothing is posted, and the log says so.

The bot must be able to post in the room: invite it, or give the Slack app `chat:write.public`. A
room notice asks nobody by name; whoever may decide the agent's calls can answer it. Like every
notice, it is sent at least once; see [Details](#details).

## What a notice says

- **Parked:** the agent, and for each waiting call its tool, the question, its arguments, and
  whether the turn had read content from outside. In Slack each call has
  [Approve and Deny](/channels/slack/#what-a-notice-says-in-slack).
- **Failed:** why the turn failed.
- **Finished:** what the turn answered. It suits an agent a [trigger](/build/triggers/) asks.

## Which orgs a target tells

A target tells the deployment's [org](/concepts/agents/#keys-and-orgs). To tell another org, list it
under that org in `orgs`, with the channel it posts through:

```yaml
channels:
  globex-slack:
    type: slack
    token: ${GLOBEX_SLACK_BOT_TOKEN}
    signing_secret: ${GLOBEX_SLACK_SIGNING_SECRET}

notify:
  globex-ops:
    channel: globex-slack
    room: "#globex-ops"

orgs:
  globex:
    channels: [globex-slack]
    notify: [globex-ops]
```

One org's calls never reach another org's room, where its people could approve them.

## Webhooks

A `webhook` target is sent each notice as JSON in a POST:

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
      "labels": ["outside"]
    }
  ],
  "reason": null,
  "text": null
}
```

With a `secret`, each body is signed as `x-wardrik-signature: sha256=<hex>`, the HMAC-SHA256 of the
raw body. Check it before parsing:

```js
import { createHmac, timingSafeEqual } from "node:crypto";

const expected = "sha256=" + createHmac("sha256", secret).update(rawBody).digest("hex");
const ok =
  signature.length === expected.length &&
  timingSafeEqual(Buffer.from(expected), Buffer.from(signature));
```

## Details

- One node of the cluster sends the notices, and keeps its place in the agents' logs. After a
  restart it carries on from there, so a notice whose delivery was cut short comes again: tell a
  repeat by its `agent`, `event` and `at`.
- A turn waiting on several calls sends a notice again when some are decided and others still wait.
- A definition [sent over HTTP](/build/http-api/#define-an-agent) takes `notify` in the same forms,
  as `"notify": {"to": ["ops"], "on": ["finished"]}`. It holds while the agent sleeps and after a
  restart, and goes when the agent is forgotten.
- An agent file routing to another org's target doesn't read; a definition over HTTP that does is
  refused.
- Webhook `event` is `turn_parked`, `turn_failed` or `turn_finished`, also in the `x-wardrik-event`
  header. `reason` is why a turn failed, `text` what it answered, and a call's `labels` what its
  turn had read first.
- The signature covers the body only, with no time, so a body sent again verifies again. Use `at`
  to refuse old ones.
- An answer other than 2xx is a failure. A failure that may pass is tried up to three more times,
  each waiting up to 10 seconds. A notice that still fails is logged and dropped.
