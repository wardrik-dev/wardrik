# Orgs

An org is the first segment of an agent's ID: `acme` for `acme/triage` and `acme/@maria/assistant`.
Give each org its own settings with a `Wardrik.Orgs` module that reads them from wherever your app
keeps orgs:

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

  * `policy` - every agent of the org is held to it, after the deployment's and before its own.
    The strictest wins. A list is held to in turn.
  * `policies` - policies the org's definitions may name, beside the deployment's. A name the
    deployment already uses is refused.
  * `defaults` - what the org's definitions get where they say nothing, over the deployment's.
  * `ceilings` - see [Ceilings](#ceilings).

Wardrik asks for an org's settings each time one of its agents starts, wakes or is defined.
Settings that don't read keep the agent from starting, and say why.

To bring the org's awake agents to settings that changed:

```elixir
Wardrik.refresh(MyApp.Wardrik, org: "acme")
#=> []
```

It returns a line for each agent it couldn't refresh. Sleeping agents take the settings as they
wake.

## Unknown orgs

Return an error for an org that doesn't exist:

```elixir
{:error, Wardrik.Error.new(:not_found, "There's no org globex here.")}
```

Its agents aren't defined or started, and nothing is kept for it: no secret, server or connection
of its owners, and no token whose resources name it, as `globex/agent/*`. A pattern that leaves the
org open, as `*/agent/*`, reaches only the orgs that exist.

## Servers per org

An MCP server under `:mcp` serves every org, unless its `orgs:` lists the ones whose agents reach
it:

```elixir
mcp: [stripe: [orgs: ["payments"], transport: {:streamable_http, base_url: "https://mcp.stripe.com"}]]
```

## Ceilings

A ceiling is a budget every agent of the org spends from together, its users' agents included. It
takes what a budget takes, except `per: :turn`.

Once the org's agents have spent its limit, the next model call any of them makes does what
`on_exhausted` says:

  * `:ask` - the default. Waits for someone allowed `ceiling.approve` on `acme/ceiling`, as an
    owner is. Approving allows the ceiling's `grant` more to the whole org for that period:

    > acme's agents have spent $20.04 of $20.00 this month. Approve to allow $20.00 more.

  * `:deny` - refuses the call.
  * `:continue` - lets it run, so work always carries on.

Reaching a ceiling's limit writes `wardrik.ceiling.reached` to the agent's log. A ceiling in
dollars refuses a model with no price, unless it continues.

`Wardrik.Ceilings.list/2` returns what an org has spent against each ceiling. It needs
`ceiling.read` on `acme/ceiling`, as a reader has. Over HTTP it's `GET /v1/ceilings?owner=acme`.

```elixir
Wardrik.Ceilings.list(scope, owner: "acme")
#=> {:ok, [%Wardrik.Spend{ceiling: "plan", per: :month, limit: %Wardrik.Amount{usd: 20.0}, ...}]}
```
