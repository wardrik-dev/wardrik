---
title: Budgets
description: "Require approval or stop further model calls when spending reaches a per-turn, periodic, or lifetime threshold."
sidebar:
  order: 5
---

Set a budget in the agent’s policy to track spending in dollars, tokens, or both. Once the
threshold is reached, further model calls require approval or the turn ends.

```yaml title="~/.config/wardrik/policies/careful.yaml"
budget:
  usd: 5.00
  tokens: 200000
  per: day            # turn, day, week, month or total
  grant: {usd: 2.00}
  on_exhausted: ask   # or deny
```

Budgets are checked before model calls. The call that crosses the threshold still completes;
the next model call requires approval:

> This agent has spent $5.02 of $5.00 today. Approve to allow $2.00 more.

- Tool costs count toward spending, but the budget does not block tool calls.
- Approving adds the amount in `grant`. `on_exhausted: deny` ends the turn instead.
- An agent's conversations share its budget. An org policy's budget is shared by the org's agents.
- Prices come from the provider, then the model catalog, then `config.yaml`'s `models`.
- `wardrik ls` shows each agent's spend today. Each `message.completed` and `tool_call.completed`
  [event](/concepts/events/) has a `cost`.

See all budget settings in [Policies › Budgets](/reference/policies/#budgets).
