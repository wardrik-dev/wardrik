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
allow `shell/*`. An org's policy sits between them; see [Orgs](orgs.md).

## Budgets

A budget caps what an agent spends on its model. The call that crosses the limit runs, and the next
one waits for a person to allow more:

> This agent has spent $5.02 of $5.00 today. Approve to allow $5.00 more.

## Gated tools

A gated tool can change something: an MCP server's tool it doesn't mark read-only, a worker's, and
`agents/*`' changes. Its calls wait for a person unless a rule allows them by name, so an agent with
no policy still asks before one.

## After content from outside

Once a run has read content from outside, every gated call waits for a person, whatever `allow`
says, since what it read may be what asked for it:

> linear/create_issue is allowed, but this run has read content from outside, which may be what
> asked for it.

Content from outside is what nobody on the agent's side wrote: `web_search`'s results, an MCP
server's answers unless its `trusted` option says otherwise, a worker's unless the Wardrik's
`:trusted_workers` does, what a feed or webhook trigger brings, and an answer or message from an
agent that had read any of these. The label stays with the conversation until it's cleared. The
waiting call's `Wardrik.Interrupt` carries it as `labels`.

`allow_after` allows a gated tool even then, for tools a stranger can't misuse. An `ask` or `deny`
still wins over it. Only an agent a file declares writes it in place; any other names a policy in
the Wardrik's `:policies` that has it:

```elixir
config :my_app, MyApp.Wardrik,
  policies: [triage: [allow: ["linear/*"], allow_after: %{"outside" => ["github/add_labels"]}]]
```

## Every rule

Rules can name a tool, what a call acts on, or its arguments, and a judge can ask a model what a
call means. See [WardrikPolicy](https://hexdocs.pm/wardrik_policy) for every rule.

A policy is given as its rules, or as a `WardrikPolicy` you built.
