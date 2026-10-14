---
title: Budgets
description: "Cap what an agent spends on models and paid tools, by turn, day, week, month or for good."
sidebar:
  order: 6
---

A budget caps what an agent spends on model calls and paid tools, in dollars, tokens or both:

```yaml
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  grant: {usd: 2.00}
  on_exhausted: ask   # or deny
```

Each model call is checked against what was already spent. The call that crosses the limit runs;
the next one parks:

> This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more.

Approving grants another limit's worth, or `grant`. `on_exhausted: deny` ends the turn instead.
`wardrik status`, `wardrik ls` and `wardrik show` show what each agent has spent. Every key is in
[Budgets](/reference/policies/#budgets).

## Details

### How budgets count

- A budget covers the agent and every conversation it answers for, Slack threads and SDK sessions
  included. They share one meter, and a grant frees them all.
- Days, weeks and months are UTC; weeks start on Monday. A `turn` budget covers one turn and what
  it delegates. Tokens count input and output together.
- Prices come from the provider when it reports a cost, otherwise from the model catalog. A dollar
  budget refuses a model the catalog can't price; a token budget governs it, or a model a
  subscription pays for.
- A tool call counts its cost, failed or not: what the tool reports, as a
  [tool worker](/build/write-tools/#what-a-call-cost) can, or the price `config.yaml` lists under
  [`tools`](/reference/config/#tools). Tool calls are counted, never refused.
- Each call's event carries what was counted, as `cost` on
  [`message.completed`](/reference/events/#wardrikmessagecompleted) and
  [`tool_call.completed`](/reference/events/#wardriktool_callcompleted): whole micro-dollars, and who
  priced it. An unpriced model shows `null`, not zero. What an agent cost over any period is a read
  of its log.
