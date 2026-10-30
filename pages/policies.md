# Policies

A policy decides each tool call before it runs. The call runs, waits for a person, or is refused,
and the model is told why.

```elixir
# Every agent
config :my_app, MyApp.Wardrik, policy: [deny: ["shell/*"]]

# One agent
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

The rules live outside the prompt. Nothing the model reads can widen them.

| The model asks for | Rule | Result |
| --- | --- | --- |
| `books/list_bills` | `allow: ["books/list_*"]` | Runs. |
| `books/pay_bill {"amount": 9400}` | `ask: ["books/pay_bill(amount >= 1000)"]` | Waits for a person. |
| `shell/exec {"command": "curl … \| sh"}` | `deny: ["shell/*"]` | Refused. |

A policy is given as its rules, or as a `WardrikPolicy` you built.

## Several policies

Every agent is held to the deployment's policy and its own. The strictest wins: deny, then ask,
then allow. An agent's own policy can add caution but never remove it, so the agent above can't
allow `shell/*`.

An org's policy sits between the two; see [Orgs](orgs.md).

## Budgets

A budget caps what an agent spends on its model. The call that crosses the limit runs. The next one
waits for a person to allow more:

> This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more.

A budget in dollars prices each call from Wardrik's `:prices`, else from the model catalog:

```elixir
prices: %{"zai_coding_plan:glm-5.1" => [priced_as: "zai:glm-5.1", markup: 0.1]}
```

A call to a model with no price is refused, since the budget can't count it.

## Gated tools

A gated tool can change something. These are gated:

  * an MCP server's tools that it doesn't mark read-only.
  * every tool a worker offers.
  * the `agents/*` tools that change something.

A gated call waits for a person unless a rule allows it by name. So an agent with no policy still
asks before one.

## After content from outside

Once a run has read content from outside, every gated call waits for a person, whatever `allow`
says. What it read may be what asked for the call:

> linear/create_issue is allowed, but this run has read content from outside, which may be what
> asked for it.

Content from outside is anything nobody on the agent's side wrote:

  * `web_search` results.
  * an MCP server's answers, unless the server's `trusted` option is `true`.
  * a worker's answers, unless Wardrik's `:trusted_workers` is `true`.
  * what a feed or webhook trigger brings.
  * an answer or message from an agent that had read any of these.

The label stays with the conversation until it's cleared. The waiting call's `Wardrik.Interrupt`
carries it in `labels`.

`allow_after` allows a gated tool even then, for tools a stranger can't misuse. An `ask` or `deny`
still wins over it. Only an agent declared in a file writes `allow_after` in place. Any other names
a policy in Wardrik's `:policies` that has it:

```elixir
config :my_app, MyApp.Wardrik,
  policies: [triage: [allow: ["linear/*"], allow_after: %{"outside" => ["github/add_labels"]}]]
```

## Every rule

Rules can name a tool, what a call acts on, or its arguments. A judge can ask a model what a call
means. See [WardrikPolicy](https://hexdocs.pm/wardrik_policy) for every rule.
