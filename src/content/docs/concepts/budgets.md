---
title: Budgets
description: "Cap what an agent spends on model calls, by turn, day, week, month or for good."
sidebar:
  order: 5
---

A budget caps what an agent spends on model calls, in dollars, tokens or both. It goes in a
policy.

```yaml title="~/.config/wardrik/policies/careful.yaml"
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  grant: {usd: 2.00}
  on_exhausted: ask   # or deny
```

The call that crosses the limit runs. The next one waits for a person:

> This agent has spent $5.02 of $5.00 today. Approve to allow $2.00 more.

- Approving allows `grant` more, or another limit's worth.
- `on_exhausted: deny` ends the turn instead.
- `wardrik ls` shows what each agent spent today.
- An agent and all its conversations share one budget.
- A budget in an org's policy is shared by every agent in the org.
- Days start at midnight UTC unless `timezone` is set. Weeks start on Monday.
- Prices come from the provider, then the model catalog, then `config.yaml`'s `models`.
- A dollar budget refuses a model nothing prices. Give it a `price`, or use a token budget.
- Tool calls count what the tool reports it cost. They are never refused.
- Each `message.completed` and `tool_call.completed` [event](/concepts/events/) carries its `cost`.

Every key is in [Policies › Budgets](/reference/policies/#budgets).
