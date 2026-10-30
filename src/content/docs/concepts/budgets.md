---
title: Budgets
description: "Cap what an agent spends on models and paid tools, by turn, day, week, month or for good."
sidebar:
  order: 6
---

A budget caps what an agent spends on model calls, in dollars, tokens or both. It goes in a
policy:

```yaml title="~/.config/wardrik/policies/careful.yaml"
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  grant: {usd: 2.00}
  on_exhausted: ask   # or deny
```

Each model call is checked against what was already spent. The call that crosses the limit runs.
The next one parks:

> This agent has spent $5.02 of $5.00 today. Approve to allow $2.00 more.

Approving grants another limit's worth, or `grant`. `on_exhausted: deny` ends the turn instead.
`wardrik ls` shows what each agent has spent today. Every key is in
[Budgets](/reference/policies/#budgets).

## Details

### How budgets count

- A budget covers the agent and every conversation it answers for, Slack threads included. They
  share one meter, and a grant frees them all.
- An agent held to several budgets, such as its own and its [org's policy](/run/orgs/#hold-an-org-to-a-policy),
  counts each apart. A call counts once in each, and more approved on one loosens no other.
- An org's policy is one budget for all of the org's agents, its users' included. Each spends from
  it, and a grant frees them all. A `per: turn` budget in it stays each agent's own.
- Days, weeks and months are UTC unless `timezone` names another zone, as `Europe/Berlin`. Weeks
  start on Monday.
- A `turn` budget covers one turn and what it delegates, subagents included.
- Tokens count input and output together.
- Prices come from the provider when it reports a cost, otherwise from the model catalog, or
  `config.yaml`'s `models` for a model the catalog lacks. A budget's own `price` prices the rest.
  A dollar budget refuses a model nothing prices. A token budget governs it, or a model a
  subscription pays for.
- A tool call counts what the tool reports it cost, failed or not, as a
  [tool worker](/build/write-tools/#what-a-call-cost) can. Tool calls are counted, never refused.
- Each call's event carries what was counted, as `cost` on
  [`message.completed`](/reference/events/#wardrikmessagecompleted) and
  [`tool_call.completed`](/reference/events/#wardriktool_callcompleted): whole micro-dollars, and who
  priced it. An unpriced model shows `null`, not zero. What an agent cost over any period is a read
  of its log.
