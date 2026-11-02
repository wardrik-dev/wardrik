---
title: Budgets
description: "Cap what an agent spends on model calls, by turn, day, week, month or for good."
sidebar:
  order: 5
---

A budget caps an agent's model spend, in dollars, tokens or both. Set it in a policy.

```yaml title="~/.config/wardrik/policies/careful.yaml"
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  grant: {usd: 2.00}
  on_exhausted: ask   # or deny
```

The call that crosses the limit runs. The next one needs approval:

> This agent has spent $5.02 of $5.00 today. Approve to allow $2.00 more.

- Approving adds `grant`. `on_exhausted: deny` ends the turn instead.
- An agent's conversations share its budget. An org policy's budget is shared by the org's agents.
- Prices come from the provider, then the model catalog, then `config.yaml`'s `models`.
- `wardrik ls` shows each agent's spend today. Each `message.completed` and `tool_call.completed`
  [event](/concepts/events/) has a `cost`.

Every key and limit rule is in [Policies › Budgets](/reference/policies/#budgets).
