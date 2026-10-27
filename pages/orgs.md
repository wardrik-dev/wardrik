# Orgs

An org is the first part of an agent's ID: `acme` for `acme/triage` and `acme/@maria/assistant`.
Give each org settings of its own with `:orgs`, a `Wardrik.Orgs` that answers them from wherever
your app keeps its orgs:

```elixir
defmodule MyApp.Orgs do
  @behaviour Wardrik.Orgs

  @impl true
  def settings(org, _config) do
    plan = MyApp.Billing.plan!(org)

    {:ok,
     %Wardrik.OrgSettings{
       policy: [deny: ["shell/*"]],
       policies: %{"careful" => [ask: ["github/*"]]},
       defaults: %{"model" => plan.model},
       ceilings: %{"plan" => [usd: plan.usd, per: :month]}
     }}
  end
end

config :my_app, MyApp.Wardrik, orgs: {MyApp.Orgs, []}
```

Every agent of the org is held to its `policy`, after the deployment's and before its own, and the
strictest decides. Its definitions may name its `policies` beside the deployment's, though not one
with a deployment policy's name, and are given its `defaults` over the deployment's. `policy` may be
a list, each held to in turn.

An org there's no such thing as answers `{:error, %Wardrik.Error{}}`, as
`Wardrik.Error.new(:not_found, "There's no org globex here.")`. Its agents aren't defined or
started, and nothing is kept for it: a secret, a server or a connection of its owners, or a token
whose resources name it, as `globex/agent/*`. A pattern that leaves the org open, as `*/agent/*`,
reaches the orgs that are.

A server Wardrik starts with, under `:mcp`, serves every org unless its own `orgs:` lists the ones
whose agents reach it:

```elixir
mcp: [stripe: [orgs: ["payments"], transport: {:streamable_http, base_url: "https://mcp.stripe.com"}]]
```

Wardrik asks for an org's settings each time one of its agents starts, wakes or is defined. Settings
that don't read keep the agent from starting, and say why. Bring the org's awake agents to settings
that changed:

```elixir
Wardrik.refresh(MyApp.Wardrik, org: "acme")
#=> []
```

## Ceilings

A ceiling is a budget every agent of the org spends from together, its users' agents too. It takes
what a budget takes, but `per: :turn`. Once they've spent its limit, the next model call any of them
makes does as `on_exhausted` says:

- `:ask`, unless set, waits for someone allowed `ceiling.approve` on `acme/ceiling`, as an owner is,
  and approving it allows the ceiling's `grant` more to the whole org for that period:

  > acme's agents have spent $20.04 of $20.00 this month. Approve to allow $20.00 more.

- `:deny` refuses it.
- `:continue` lets it run, so work always carries on.

Each ceiling's limit, as it's reached, is a `wardrik.ceiling.reached` event in the agent's log. Read
what an org has spent against each with `ceilings.list`, which needs `ceiling.read` on
`acme/ceiling`, as a reader has, from any surface, as `GET /v1/ceilings?owner=acme` over HTTP:

```elixir
Wardrik.Ceilings.list(scope, owner: "acme")
#=> {:ok, [%Wardrik.Spend{ceiling: "plan", per: :month, limit: %Wardrik.Amount{usd: 20.0}, ...}]}
```

A ceiling in dollars refuses a model with no price, unless it continues.
