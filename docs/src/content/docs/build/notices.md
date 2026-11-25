---
title: Send notifications
description: "Send Slack notifications or signed webhooks for pending approvals, failures, and completed turns."
sidebar:
  order: 7
---

Send notifications when an agent needs approval, fails, or completes a turn. Define destinations
in `config.yaml`, then select them in the agent’s `notify` setting:

```yaml title="~/.config/wardrik/config.yaml"
notify:
  targets:
    ops: {channel: slack, room: "#ops"}
    audit: {webhook: {url: https://hooks.example.com/wardrik, secret: "${WEBHOOK_SECRET}"}}
    assistant: {agent: assistant}
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

- Turns started in Slack threads show replies, approvals, and failures in that thread, without
  a separate notification.
- Slack destinations use the workspace connected to the agent’s owner or organization.
- A target is available to the deployment's org. List it under `orgs.<org>.notify` for others.
- Notices are never sent to another org's room.

## Report to an agent

An `agent` target sends each notice to that agent as a message. It answers as it sees fit, and
its own `notify` decides what people hear. Send workers' answers to one assistant, and approvals
and failures to people:

```yaml title="~/.config/wardrik/config.yaml"
notify:
  targets:
    me: {channel: slack, room: U012AB3CD}
    assistant: {agent: assistant}
defaults:
  notify:
    - {to: [me], on: [parked, failed]}
    - {to: [assistant], on: [finished]}
```

- The agent is the one of that name in the notifying agent's org.
- `conversation` asks it in a conversation of its own, apart from people's:
  `assistant: {agent: assistant, conversation: reports}`.
- The message starts `From agent NAME (ID):` and carries the notifying conversation's labels.
- An agent never notifies itself.
- An answer of `NO_REPLY` reaches no agent. See [Answer nothing](#answer-nothing).

## Answer nothing

An agent that answers `NO_REPLY` sends no notice for that turn. Tell an agent on a trigger to
answer it when a run finds nothing worth telling:

```yaml
# in an agent file
notify: {to: [ops], on: [parked, failed, finished]}
triggers:
  - name: pulse
    every: 2h
    prompt: Check for failed runs. If there are none, answer NO_REPLY.
```

- The answer stays in the agent's history.
- `NO_REPLY` must be the whole answer. Code or bold around it is ignored.
- It costs nothing more, and works with any model. Use a judge for answers that need weighing.

## Judge finished turns

A judge decides whether each finished turn's answer is sent. Use it for agents that run on
triggers, so people hear only what matters.

```yaml
# in an agent file
notify:
  to: [ops]
  on: [parked, failed, finished]
  judge:
    question: Would the owner want to hear this now, rather than in the next digest?
    send: 0.7
```

- The judge model reads the answer and the conversation's digest, and gives the probability of
  yes.
- The answer is sent at or above `send`. Otherwise it is held, and `wardrik.notice.held` is
  written to the audit log with the probability.
- Parked and failed turns are always sent.
- If the judge can't answer, the answer is sent.
- Start with a high `send` and lower it as the agent earns trust.
- Each judge call is recorded as `wardrik.evaluation.completed`, with its answers and cost, sent
  or held. Its cost counts toward the agent's spending. Set `TYPESAFE_API_KEY` for the default
  model.
- Text in the answer can sway the judge. Use it to cut noise, not to keep secrets.

## Webhooks added at runtime

An org or user can add a webhook for their own agents:

```sh
echo "$SECRET" | wardrik vault put HOOK_SECRET --org acme --for signing_secret
wardrik notify add alerts --org acme --url https://hooks.acme.example/wardrik --secret HOOK_SECRET
```

Reference the webhook in an agent file with `notify: alerts`.

## Webhook payload

```json
{
  "event": "turn_parked",
  "agent": "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN",
  "name": "ops-watch",
  "conversation": null,
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
- `name` is the agent's `display_name`, or its name in `agents/` or the API. `conversation` is
  `null` for the agent's main conversation.
- In Slack, a notice shows the agent's name, with its ID in small text. The message carries
  this payload as its metadata.
- Delivery is at least once. Deduplicate by `agent`, `event` and `at`.
- The signature covers the body only. Use `at` to reject replays.
- Transient failures are retried. `notify.retries` configures it.
- A webhook added at runtime must be `https` at a public address.
