# Orgs

An org is the first segment of an agent's ID: `acme` for `acme/triage` and `acme/@maria/assistant`.
Give each org its own settings with a `Wardrik.Orgs` module. It reads them from wherever your app
keeps orgs. Here, a map stands in for your billing plans.

## Setup

In a fresh IEx session:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.1"}])

defmodule MyApp.Orgs do
  @behaviour Wardrik.Orgs

  @plans %{"acme" => %{model: "anthropic:claude-haiku-4-5", usd: 20.00}}

  @impl true
  def settings(org, _config) do
    case Map.fetch(@plans, org) do
      {:ok, plan} ->
        {:ok,
         %Wardrik.OrgSettings{
           policy: [deny: ["shell/*"]],
           policies: %{"careful" => [ask: ["github/*"]]},
           defaults: %{"model" => plan.model},
           ceilings: %{"plan" => [usd: plan.usd, per: :month]}
         }}

      :error ->
        {:error, Wardrik.Error.new(:not_found, "There's no org #{org} here.")}
    end
  end
end

{:ok, _} = Wardrik.start_link(name: MyApp.Wardrik, orgs: {MyApp.Orgs, []})

scope =
  Wardrik.as(MyApp.Wardrik, "acme/@maria",
    roles: [:owner],
    resources: ["acme/@maria/*", "acme/ceiling"]
  )
```

  * `policy` - every agent of the org is held to it, after the deployment's and before its own.
    The strictest wins. A list is held to in turn.
  * `policies` - policies the org's definitions may name, beside the deployment's. A name the
    deployment already uses is refused.
  * `defaults` - what the org's definitions get where they say nothing, over the deployment's.
  * `ceilings` - see [Ceilings](#ceilings).

An acme definition can leave out `model`, and name `careful`:

```elixir
Wardrik.Agent.define(scope, "acme/@maria/assistant", policy: "careful")
#=> {:ok, %Wardrik.Agent{id: "acme/@maria/assistant", status: :idle, ...}}
```

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

`settings/2` above returns an error for an org that doesn't exist. Its agents aren't defined or
started:

```elixir
sam = Wardrik.as(MyApp.Wardrik, "globex/@sam", roles: [:owner], resources: ["globex/@sam/*"])

Wardrik.Agent.define(sam, "globex/@sam/assistant", model: "anthropic:claude-haiku-4-5")
#=> {:error, %Wardrik.Error{type: :not_found, message: "There's no org globex here."}}
```

Nothing is kept for it either: no secret, server or connection of its owners, and no token whose
resources name it, as `globex/agent/*`. A pattern that leaves the org open, as `*/agent/*`, reaches
only the orgs that exist.

## Servers per org

An MCP server in Wardrik's `:mcp` option serves every org, unless its `orgs:` lists the ones whose
agents reach it, as `[stripe: [orgs: ["payments"], transport: ...]]`. See [MCP servers](servers.md).

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
#=> {:ok,
#=>  [
#=>    %Wardrik.Spend{
#=>      ceiling: "plan",
#=>      per: :month,
#=>      on_exhausted: :ask,
#=>      limit: %Wardrik.Amount{usd: 20.0, tokens: nil},
#=>      spent: %Wardrik.Amount{usd: 0, tokens: 0},
#=>      starts_over: ~D[2026-11-01],
#=>      ...
#=>    }
#=>  ]}
```
