---
title: Send notices
description: "Have agents tell people when they wait on a person, fail or answer, in a Slack room or at a signed webhook."
sidebar:
  order: 7
---

Name targets in `config.yaml`, then route an agent's notices to them:

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
notify: {to: ["slack:#updates"], on: [finished]}    # a room, with no target
```

| `on` | Sent when |
| --- | --- |
| `parked` | a turn waits on a person; in Slack each call has **Approve** and **Deny** |
| `failed` | a turn fails, with why |
| `finished` | a turn answers, with its answer |

`on` is `[parked, failed]` unless set.

- A room posts in the workspace the channel is added to for the agent's owner, or its org.
- A target serves the deployment's org. List it under `orgs.<org>.notify` for another.
- One org's calls never reach another org's room.

## Webhooks people add

An org or person adds a webhook for their own agents:

```sh
echo "$SECRET" | wardrik vault put HOOK_SECRET --org acme --for signing_secret
wardrik notify add alerts --org acme --url https://hooks.acme.example/wardrik --secret HOOK_SECRET
```

Agents route to it as `notify: alerts`.

## What a webhook gets

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

- `event` is `turn_parked`, `turn_failed` or `turn_finished`, also in the `x-wardrik-event` header.
- A notice is sent at least once. Tell a repeat by its `agent`, `event` and `at`.
- The signature covers the body only. Use `at` to refuse old ones.
- A failure that may pass is retried. `notify.retries` sets how.
- A people-added webhook must be `https` at a public address.
