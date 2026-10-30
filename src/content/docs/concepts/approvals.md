---
title: Approvals
description: "A call that waits parks its turn until a person approves or denies it, from a shell, Slack or the HTTP API."
sidebar:
  order: 4
---

A call that waits parks the turn. Nothing more runs until each waiting call is decided. A parked
turn is stored, so it survives its node, and it never times out.

```sh
wardrik approval ls
wardrik approval approve acme/triage call_1 --note "Label it for the next sprint."
wardrik approval deny acme/triage call_1 --reason "Not on a Friday."
```

```text
AGENT        CALL    TOOL                  WHY
acme/triage  call_1  github__create_issue  This opens an issue on GitHub.
```

You can also decide in [Slack](/channels/slack/), where the call's arguments show with Approve and
Deny, or over the HTTP API.

- **A denial** reaches the model as an error with your reason, and the turn carries on.
- **An approval** runs the call exactly as the model wrote it. A note is passed to the model beside
  the result. It steers what comes next but never changes the call. To change the call, deny it and
  say what to do.

## Changing the policy while it waits

A waiting call keeps waiting until a person decides it, even if the policy changes. To have the
agent drop it, cancel the turn with `wardrik agent cancel AGENT`.

## Details

### While a call waits

- An agent's `timeout` starts again when the turn carries on.
- Messages that arrive wait behind the parked turn. Cancelling the turn abandons it, and them.
- In a round of several calls, the allowed ones have already run. Each waiting call is decided on
  its own, in any order. The model gets the round's answers once all are decided.
- `wardrik approval ls` marks a call held because its turn read
  [content from outside](/concepts/outside-content/): `[after content from outside]`. The API
  carries `labels: ["outside"]`.
- An approval's note reaches the model as `"note"` beside the result:
  `{"ok": true, "result": {"number": 412}, "note": "Label it for the next sprint."}`.
- A model call refused by a budget ends the turn.

### Over HTTP

| Route | Decides |
| --- | --- |
| `POST /v1/agents/{agent}/interrupts/{call}/approve` | one call, with an optional `{"note": "..."}` |
| `POST /v1/agents/{agent}/interrupts/{call}/deny` | one call, with an optional `{"reason": "..."}` |
| `POST /v1/agents/{agent}/decisions` | several calls at once |

```json
{"decisions": [{"id": "call_1", "decision": "approve", "note": "Only staging."},
               {"id": "call_2", "decision": "reject", "reason": "Not this quarter."}]}
```

The token needs the `approver` role on the agent. `GET /v1/interrupts` lists every call waiting.

### Connecting an account

A call that needs an account the user hasn't connected parks the same way, with a link to authorize
instead of a question. The call carries on once the account is connected. See
[Connect accounts](/build/accounts/).
