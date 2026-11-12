---
title: Approvals
description: "A tool call that needs approval pauses its turn until a person approves or denies it, from the terminal, Slack or HTTP."
sidebar:
  order: 3
---

When a policy requires approval, Wardrik pauses the turn and saves its state. Approve or deny the
call to resume. Pending approvals survive restarts and have no expiry.

```sh
wardrik approval
wardrik approval ls
wardrik approval approve triage call_1 --note "Label it for the next sprint."
wardrik approval deny triage call_1 --reason "Not on a Friday."
```

- `wardrik approval` prompts you to approve or deny each pending call. Press Enter to leave it pending.
- In an interactive terminal, `wardrik ask` and `wardrik follow` also prompt for approval.

- Approving runs the call with the model's arguments. The model receives the `--note` with the result.
- Denying returns an error with your `--reason` to the model. The turn continues.
- To change a call, deny it and say what to do instead.
- For a call in a conversation, pass `--conversation ID`. `approval ls` shows the ID.

## Over HTTP

```sh
curl -X POST -H "authorization: Bearer $TOKEN" \
  -d '{"note": "Only staging."}' \
  http://127.0.0.1:4747/v1/agents/agt_1/interrupts/call_1/approve
```

| Route | Does |
| --- | --- |
| `POST /v1/agents/{agent}/interrupts/{interrupt}/approve` | approves one call |
| `POST /v1/agents/{agent}/interrupts/{interrupt}/deny` | denies one call, with an optional `reason` |
| `POST /v1/agents/{agent}/decisions` | approves or denies several calls |
| `GET /v1/interrupts` | lists every pending call |

A conversation's calls are under `/v1/agents/{agent}/conversations/{conversation}/...`.

## Who can approve

- Over HTTP: a user or agent with a role permitting `approve`, `deny`, or `decide` on the target agent.
- In a chat channel: the person who sent the message that started the turn.
- The `wardrik` command, which runs as the admin.

## While a call is pending

- Allowed calls in the same round have already run.
- Each pending call is approved or denied separately. The model receives the round's results
  once all are resolved.
- New messages are queued until the turn resumes.
- `wardrik agent cancel` ends the turn and drops the queued messages.
- Calls that require an account connection also pause the turn until the user signs in. See
  [Connect accounts](/build/accounts/).
