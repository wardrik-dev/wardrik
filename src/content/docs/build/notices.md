---
title: Send notices
description: "Send a notice to a Slack room or a signed webhook when a turn pauses for approval, fails or finishes."
sidebar:
  order: 7
---

Define targets in `config.yaml`, then set an agent's `notify`:

```yaml title="~/.config/wardrik/config.yaml"
notify:
  targets:
    ops: {channel: slack, room: "#ops"}
    audit: {webhook: {url: https://hooks.example.com/wardrik, secret: "${WEBHOOK_SECRET}"}}
```

```yaml
# in an agent file
notify: ops                                         # parked and failed turns
notify: {to: [ops, audit], on: [parked, failed, finished]}
notify: {to: ["slack:#updates"], on: [finished]}    # a room, without a target
```

| `on` | Sent when |
| --- | --- |
| `parked` | a turn pauses for approval; in Slack each call has **Approve** and **Deny** |
| `failed` | a turn fails, with the error |
| `finished` | a turn completes, with the reply |

`on` defaults to `[parked, failed]`.

- In Slack, a notice for a turn in a thread isn't posted. The thread shows the turn's answer,
  approvals and failure.
- A room is in the workspace where the channel was added for the agent's owner or org.
- A target is available to the deployment's org. List it under `orgs.<org>.notify` for others.
- Notices are never sent to another org's room.

## Webhooks added at runtime

An org or user can add a webhook for their own agents:

```sh
echo "$SECRET" | wardrik vault put HOOK_SECRET --org acme --for signing_secret
wardrik notify add alerts --org acme --url https://hooks.acme.example/wardrik --secret HOOK_SECRET
```

Agents use it as `notify: alerts`.

## Webhook payload

```json
{
  "event": "turn_parked",
  "agent": "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN",
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

With a `secret`, the body is signed as `x-wardrik-signature: sha256=<hex>`, the HMAC-SHA256 of the
raw body:

```js
import { createHmac, timingSafeEqual } from "node:crypto";

const expected = "sha256=" + createHmac("sha256", secret).update(rawBody).digest("hex");
const ok =
  signature.length === expected.length &&
  timingSafeEqual(Buffer.from(expected), Buffer.from(signature));
```

## Details

- `event` is `turn_parked`, `turn_failed` or `turn_finished`, also sent as the `x-wardrik-event`
  header.
- Delivery is at least once. Deduplicate by `agent`, `event` and `at`.
- The signature covers the body only. Use `at` to reject replays.
- Transient failures are retried. `notify.retries` configures it.
- A webhook added at runtime must be `https` at a public address.
