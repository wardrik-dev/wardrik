---
title: Approvals
description: "A call that waits parks its turn until a person approves or denies it, from a shell, Slack, the terminal client or the API."
sidebar:
  order: 3
---

A call that waits parks the turn. Nothing more runs until each waiting call is decided. A parked
turn is stored, so it survives its node, and it never times out.

```sh
wardrik parked
wardrik approve acme/triage call_1 Label it for the next sprint.
wardrik deny acme/triage call_1 Not on a Friday.
```

```text
1 waiting:
  acme/triage  call_1  github/create_issue  This opens an issue on GitHub.
```

You can also decide in [Slack](/channels/slack/), where the call's arguments show with Approve and
Deny, in the [terminal client](/build/tui/), or with `POST /v1/agents/{key}/decisions`.

- **A denial** reaches the model as an error with your reason, and the turn carries on.
- **An approval** runs the call exactly as the model wrote it. A note is passed to the model beside
  the result; it steers what comes next but never changes the call. To change the call, deny it and
  say what to do.

## Changing the policy while it waits

`wardrik reload` re-decides calls a rule asked about, under the policy as it is now. Gated calls,
and calls waiting for an account, keep waiting.

## Details

### While a call waits

- An agent's `timeout` starts again when the turn carries on.
- Messages that arrive wait behind the parked turn. `POST /v1/agents/{key}/cancel` abandons it.
- In a round of several calls, the allowed ones have already run. Each waiting call is decided on
  its own, in any order; the model gets the round's answers once all are decided.
- `wardrik approve` and `deny` without a call list what's waiting and ask which, if someone is at the
  terminal.
- Over HTTP, decide with `{"decisions": [{"id": "...", "decision": "approve"}]}`, adding a `"note"`,
  or `"decision": "reject"` with a `"reason"`. The token needs `decide`. The terminal client uses
  Ctrl-Y and Ctrl-N.
- `wardrik parked` and the HTTP API don't show a call's arguments; the Slack notice and the
  [webhook](/build/notices/#webhooks) do. Each shows what the turn had read: `wardrik parked` and
  Slack say so under the question, and the API and webhook carry `labels: ["outside"]`.
- An approval's note reaches the model as `"note"` beside the result:
  `{"ok": true, "result": {"number": 412}, "note": "Label it for the next sprint."}`. A note on a
  budget's question is recorded but not read by the model.
- A model call refused by a budget ends the turn.

### Connecting an account

A call that needs an account the user hasn't connected parks the same way, with a link to authorize
instead of a question; `wardrik parked` shows it. The call carries on once the account is connected.
See [Connect accounts](/build/accounts/).
