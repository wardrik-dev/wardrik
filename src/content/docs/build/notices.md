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
    app_token: ${GLOBEX_SLACK_APP_TOKEN}

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

- A notice is sent once, from the node holding the agent.
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
