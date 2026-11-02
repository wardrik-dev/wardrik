---
title: Approvals
description: "A call that waits parks its turn until a person approves or denies it, from the terminal, Slack, HTTP or Elixir."
sidebar:
  order: 3
---

A call that waits parks the turn. Nothing more runs until a person decides it. A parked turn is
stored, so it survives a restart. It never times out.

```sh
wardrik approval ls
wardrik approval approve triage call_1 --note "Label it for the next sprint."
wardrik approval deny triage call_1 --reason "Not on a Friday."
```

- An approval runs the call exactly as the model wrote it. A note reaches the model beside the
  result.
- A denial reaches the model as an error with your reason. The turn goes on.
- To change a call, deny it and say what to do instead.
- A call in a conversation needs `--conversation`, as `approval ls` shows it.

## From Elixir

```elixir
Wardrik.Agent.approve(scope, agent: "agt_1", interrupt: "call_1", note: "Only staging.")
Wardrik.Agent.deny(scope, agent: "agt_1", interrupt: "call_1", conversation: "C1", reason: "Not now.")
```

All arguments are one keyword list. An unknown key raises `ArgumentError`.

## Over HTTP

```sh
curl -X POST -H "authorization: Bearer $TOKEN" \
  -d '{"note": "Only staging."}' \
  http://127.0.0.1:4747/v1/agents/agt_1/interrupts/call_1/approve
```

| Route | Decides |
| --- | --- |
| `POST /v1/agents/{agent}/interrupts/{interrupt}/approve` | one call |
| `POST /v1/agents/{agent}/interrupts/{interrupt}/deny` | one call, with an optional `reason` |
| `POST /v1/agents/{agent}/decisions` | several calls at once |
| `GET /v1/interrupts` | lists every waiting call |

A conversation's calls are under `/v1/agents/{agent}/conversations/{conversation}/...`.

## Who may decide

- In the daemon, a binding whose role allows `approve`, `deny` or `decide` on the agent.
- In a chat channel, whoever asked for the turn, always.
- The `wardrik` command, which acts as the admin.

## While a call waits

- Allowed calls in the same round have already run.
- Each waiting call is decided on its own. The model gets the round's results once all are decided.
- New messages wait behind the parked turn.
- `wardrik agent cancel` abandons the turn and the messages behind it.
- A call that needs a connected account waits the same way, with a sign-in link. See
  [Connect accounts](/build/accounts/).
