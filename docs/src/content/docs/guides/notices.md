---
title: Send notices
description: Have agents tell people when they wait on a person, fail or answer, in a room of a channel such as Slack, or at a signed webhook.
sidebar:
  order: 4
---

An agent nobody is watching can tell someone when it parks on a question, fails, or answers.
`config.yaml` names the targets under `notify`, and each agent file routes its notices to them. A
target is a room in one of [`channels`](/channels/), here one Slack app called `slack`, or a
webhook:

```yaml title="~/.config/wardrik/config.yaml"
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}

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

`on` is what is sent: `parked`, `failed`, and `finished` for what a turn answered. It is
`[parked, failed]` unless set. A notice is sent once, from the node holding the agent.

**Parked:** which agent is waiting, and for each call its tool, what the policy asks, whether the
turn had read content from outside first, and its arguments. In Slack, each call has
[Approve and Deny](/channels/slack/#what-a-notice-says-in-slack) buttons. **Failed:** why the turn
failed. **Finished:** what the turn answered, which suits an agent on a
[schedule](/guides/schedules/).

A turn waiting on several calls sends a notice again when some are decided and others still wait.

## Which orgs a target tells

A target tells the agents of the deployment's [org](/concepts/agents/#keys-and-orgs) unless its
`org` names others, or `*` for every org:

```yaml
channels:
  slack: {type: slack, token: "${SLACK_BOT_TOKEN}", app_token: "${SLACK_APP_TOKEN}"}
  globex-slack: {type: slack, token: "${GLOBEX_SLACK_BOT_TOKEN}", app_token: "${GLOBEX_SLACK_APP_TOKEN}"}

notify:
  ops:
    channel: slack
    room: "#ops"
  globex-ops:
    org: globex
    channel: globex-slack
    room: "#globex-ops"
```

An agent file that routes to another org's target does not read, so one org's calls never reach
another's channel, where its people could approve them.

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
      "labels": ["outside"]
    }
  ],
  "reason": null,
  "text": null
}
```

`event` is `turn_parked`, `turn_failed` or `turn_finished`, and is in the `x-wardrik-event` header
too. `reason` is why a turn failed, and `text` what it answered. A call's `labels` say what its
turn had read first, which may be what asked for it: `outside` for content from outside.

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
