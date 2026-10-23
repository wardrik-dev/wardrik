# Policies

A policy decides each tool call before it runs: the call runs, waits on a person, or is refused,
and the model is told why. Hold every agent to the deployment's policy, and each to its own:

```elixir
config :my_app, MyApp.Wardrik, policy: [deny: ["shell/*"]]

Wardrik.Agent.define(scope, "acme/books",
  model: "anthropic:claude-haiku-4-5",
  tools: ["books/*"],
  policy: [
    allow: ["books/list_*"],
    ask: %{"books/pay_bill(amount >= 1000)" => "A bill this size needs a person."},
    budget: [usd: 5.00, per: :day]
  ]
)
```

Notice the rules live outside the prompt. Nothing the model reads can widen them.

| The model asks for | The rule that names it | What happens |
| --- | --- | --- |
| `books/list_bills` | `allow: ["books/list_*"]` | Runs |
| `books/pay_bill {"amount": 9400}` | `ask: ["books/pay_bill(amount >= 1000)"]` | Waits for a person |
| `shell/exec {"command": "curl … \| sh"}` | `deny: ["shell/*"]` | Refused |

## Several policies

Every agent is held to the deployment's policy and its own, and the strictest decides: deny, then
ask, then allow. An agent's own policy can add caution but never remove it, so the agent above can't
allow `shell/*`.

## Budgets

A budget caps what an agent spends on its model. The call that crosses the limit runs, and the next
one waits for a person to allow more:

> This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more.

## Every rule

Rules can name a tool, what a call acts on, or its arguments, and a judge can ask a model what a
call means. See [WardrikPolicy](https://hexdocs.pm/wardrik_policy) for every rule.

A policy is given as its rules, or as a `WardrikPolicy` you built.
