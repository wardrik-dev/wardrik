# Policies

> See it in action: [Rules the model can't rewrite](../notebooks/policies-demo.livemd)

A policy decides each tool call before it runs: allow, ask a person, or deny. The model is told
why. Rules live outside the prompt, so nothing the model reads can widen them.

## Setup

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.5"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer
  def authorize(_request, _opts), do: :ok
end

# Every agent works for Maria.
defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver
  def resolve(_request, _opts), do: {:ok, %Wardrik.Resolved{principal: Wardrik.principal("maria")}}
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []},
    policy: [deny: ["shell/*"]],
    policies: [triage: [allow: ["linear/*"], allow_after: %{"outside" => ["github/add_labels"]}]]
  )

scope = Wardrik.as(MyApp.AgentRuntime, "maria")
```

- `:policy` holds every agent.
- `:policies` are policies a definition may name.

## An agent's policy

```elixir
Wardrik.Agent.define(scope, "agt_books",
  model: "anthropic:claude-haiku-4-5",
  tools: ["books/*"],
  policy: [
    allow: ["books/list_*"],
    ask: %{"books/pay_bill(amount >= 1000)" => "A bill this size needs a person."},
    budget: [usd: 5.00, per: :day]
  ]
)
```

`WardrikPolicy.decide/3` shows what rules make of a call, with no model:

```elixir
deployment = WardrikPolicy.new!(deny: ["shell/*"])

books =
  WardrikPolicy.new!(
    allow: ["books/list_*", "shell/*"],
    ask: %{"books/pay_bill(amount >= 1000)" => "A bill this size needs a person."}
  )

WardrikPolicy.decide([deployment, books], "books/list_bills")
#=> :allow

WardrikPolicy.decide([deployment, books], "books/pay_bill", arguments: %{"amount" => 9400})
#=> {:ask, "A bill this size needs a person."}

WardrikPolicy.decide([deployment, books], "shell/exec")
#=> {:deny, "shell/exec is not allowed for this agent."}
```

## Several policies

- Every agent is held to Wardrik's `:policy`, the one your resolver gives it, and its own.
- The strictest wins: deny, then ask, then allow.
- So `books` allows `shell/*`, and the call is still denied.

## Budgets

A budget caps what an agent spends on its model. The call that crosses it runs. The next waits for
a person:

> This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more.

- Dollars are priced from the model catalog. Give missing prices with `:prices`; see
  `Wardrik.start_link/1`.
- A model with no price is denied, since the budget can't count it.

## Gated tools

These are gated:

- an MCP server's tools it doesn't mark read-only.
- every tool a worker offers.
- `agents/*` tools that change something.

A gated call asks a person unless a rule allows it by name.

## Content from outside

Once a run reads content from outside, every gated call asks a person, whatever `allow` says:

> linear/create_issue is allowed, but this run has read content from outside, which may be what
> asked for it.

Content from outside is:

- `web_search` results.
- an MCP server's answers, unless the server is `trusted: true`.
- a worker's answers, unless Wardrik's `:trusted_workers` is `true`.
- what a feed or webhook trigger brings.
- a message from an agent that read any of these.

The `"outside"` label stays until the conversation is cleared. The waiting `Wardrik.Interrupt`
carries it in `labels`.

`allow_after` keeps a tool allowed even then. Only an agent file writes it in place. Other
definitions name a policy that has it:

```elixir
Wardrik.Agent.define(scope, "agt_triage",
  model: "anthropic:claude-haiku-4-5",
  tools: ["linear/*", "github/*"],
  policy: "triage"
)
#=> {:ok, %Wardrik.Agent{id: "agt_triage", ...}}

Wardrik.Agent.define(scope, "agt_triage",
  model: "anthropic:claude-haiku-4-5",
  policy: [allow_after: %{"outside" => ["github/add_labels"]}]
)
#=> {:error, %Wardrik.Error{type: :invalid_request, ...}}
```

See [WardrikPolicy](https://hexdocs.pm/wardrik_policy) for every rule, and judges.
