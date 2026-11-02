# Wardrik

**Agents, governed.**

Run agents with rules the model can't rewrite, approvals from the people you choose, budgets that
cap what they spend, and a record of everything they did.

## Install

```elixir
def deps do
  [
    {:wardrik, "~> 0.1.0-rc.2"}
  ]
end
```

## Start it

```elixir
defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app
end

# config/runtime.exs
config :my_app, MyApp.AgentRuntime,
  authorizer: {MyApp.Authorizer, []},
  resolver: {MyApp.Agents, []},
  store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"},
  policy: [deny: ["shell/*"]]

# application.ex
children = [MyApp.AgentRuntime]
```

Two modules of your app are required:

- `:authorizer`, a `Wardrik.Authorizer`, says who may do what. See [Who may do what](pages/access.md).
- `:resolver`, a `Wardrik.Resolver`, says who each agent works for and what it reaches.

```elixir
defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver

  @impl true
  def resolve(%Wardrik.Resolver.Request{agent: id}, _opts) do
    agent = MyApp.Repo.get!(MyApp.Agent, id)
    {:ok, %Wardrik.Resolved{principal: Wardrik.principal(agent.user_id)}}
  end
end
```

## Talk to agents

```elixir
scope = MyApp.AgentRuntime.as("maria")

{:ok, agent} =
  Wardrik.Agent.define(scope, "agt_assistant",
    model: "anthropic:claude-haiku-4-5",
    instructions: "You keep Maria's notes.",
    policy: [budget: [usd: 1.00, per: :day]]
  )

Wardrik.Agent.reply(scope, agent, "What did I note yesterday?")
#=> {:ok, %Wardrik.Reply{text: "You noted the Q3 numbers...", ...}}

scope
|> Wardrik.Agent.stream(agent, "Summarize yesterday's notes.")
|> Enum.each(&IO.write/1)
```

## See it in action

Each notebook runs in Livebook. Start with [Wardrik in ten minutes](notebooks/tour-demo.livemd).

- [Rules the model can't rewrite](notebooks/policies-demo.livemd)
- [A person in the loop](notebooks/approvals-demo.livemd)
- [Give agents tools](notebooks/tools-demo.livemd)
- [Spend you can cap](notebooks/budgets-demo.livemd)
- [Agents that survive a crash](notebooks/durability-demo.livemd)
- [Agents that wake themselves](notebooks/triggers-demo.livemd)
- [See everything an agent did](notebooks/events-demo.livemd)
- [Who may do what](notebooks/access-demo.livemd)

## Guides

- [Run Wardrik](pages/running-wardrik.md): options, stores and nodes.
- [Talk to agents](pages/talking.md): ask, stream and reply.
- [Define agents](pages/definitions.md): definitions, sleep and conversations.
- [Trigger agents](pages/triggers.md): clocks, feeds and webhooks.
- [Policies](pages/policies.md): rules and budgets.
- [Who may do what](pages/access.md): your authorizer.
- [Operations](pages/operations.md): every operation as a function.
- [Approvals](pages/approvals.md): decide the calls agents wait on.
- [MCP servers](pages/servers.md): servers agents call.
- [Credentials and sign-ins](pages/credentials.md): sealed secrets and OAuth.
- [Events and the audit](pages/events.md): follow what agents and people did.
- [Over HTTP](https://hexdocs.pm/wardrik_http): every operation as a route.

## License

Apache-2.0
