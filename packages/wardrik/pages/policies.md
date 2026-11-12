# Policies

> See it in action: [Tool policies](../notebooks/policies-demo.livemd)

A policy decides each tool call before it runs: allow, ask a person, or deny. The model is told
why. Rules are configured outside the prompt. Model input cannot change them.

## Setup

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.10"}])

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

- `:policy` applies to every agent.
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

`Wardrik.Policy.decide/3` shows what rules make of a call, with no model:

```elixir
deployment = Wardrik.Policy.new!(deny: ["shell/*"])

books =
  Wardrik.Policy.new!(
    allow: ["books/list_*", "shell/*"],
    ask: %{"books/pay_bill(amount >= 1000)" => "A bill this size needs a person."}
  )

Wardrik.Policy.decide([deployment, books], "books/list_bills")
#=> :allow

Wardrik.Policy.decide([deployment, books], "books/pay_bill", arguments: %{"amount" => 9400})
#=> {:ask, "A bill this size needs a person."}

Wardrik.Policy.decide([deployment, books], "shell/exec")
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
- `agents/*` and `ops/` tools that change something.

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

## Rules

```elixir
# a tool
"web_search"
# every tool from the github MCP server
"github/*"
# what the call acts on, from the tool's resources annotation
"write_file(notes/*)"
# an argument: =, !=, >, >=, < or <=
"books/create_bill(amount >= 1000)"
# commas join conditions that must all hold
"email/send(to != *@acme.com)"
```

- A call no rule names follows `default:`, `:allow` unless set.
- An MCP tool named `github__create_issue` also matches as `github/create_issue`.
- `Wardrik.Policy.explain/3` returns the rule that decided a call.

`default:` can decide by a tool's annotations. Where a tool has several, the strictest wins.
`else` covers tools with none:

```elixir
policy =
  Wardrik.Policy.new!(
    allow: ["github/create_issue"],
    default: [destructive: :deny, read_only: :allow, else: :ask]
  )

Wardrik.Policy.decide(policy, "github__list_issues", annotations: %{read_only: true})
#=> :allow
```

`Wardrik.Policy.decode/2` reads a policy from a map with string keys, such as parsed YAML:

```yaml
allow: [web_search]
deny: ["email/send(to != *@acme.com)"]
default: ask
budget:
  usd: 5.00
  per: day
```

## Judges

A judge asks a model yes-or-no questions about a call:

```elixir
policy =
  Wardrik.Policy.new!(
    judge: [
      questions: [
        [question: "Does this call send money outside the company?", tools: ["books/*"], ask: 0.5, deny: 0.9]
      ]
    ]
  )

Wardrik.Policy.decide(policy, "books__pay_bill",
  arguments: %{"amount" => 1200},
  evaluate: fn _model, _call, _questions -> {:ok, [0.72], %{usd: 0.0001}} end
)
#=> {:ask, "Judged 72% likely: Does this call send money outside the company?"}
```

- A judge's allow never overrides a rule's ask or deny.
- Arguments can be written to fool a judge. Keep exact checks in rules.
- See `Wardrik.Policy.Judge` for every key, and `Wardrik.Policy.Budget` for budgets'.

## With WardrikCore alone

A policy runs as middleware on a `WardrikCore` agent, without Wardrik:

```elixir
policy = Wardrik.Policy.new!(ask: ["books/*"])

{:ok, agent} =
  WardrikCore.start_agent(
    agent_id: "books",
    model: "anthropic:claude-haiku-4-5",
    middleware: [{Wardrik.Policy.Middleware, policy}]
  )

# A call that asks parks as a Wardrik.Policy.Ask. Resume it by its call ID, or "model" for a budget.
WardrikCore.resume(agent, %{"call_123" => {:approve, "Checked with finance."}}, %{by: "user:maria"})
```

- What the agent spent survives restarts.
- Set a tool's `resources` annotation so rules can match what it acts on.
- See `Wardrik.Policy.Middleware` for its telemetry.
