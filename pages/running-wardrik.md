# Run Wardrik

> See it in action: [Agents that survive a crash](../notebooks/durability-demo.livemd)

Make Wardrik a module of your app, and add it to your supervision tree:

```elixir
defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app
end

children = [MyApp.AgentRuntime]
```

## Try it in IEx

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.4"}])

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

defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app
end

{:ok, _} =
  MyApp.AgentRuntime.start_link(authorizer: {MyApp.AllowAll, []}, resolver: {MyApp.Agents, []})

scope = MyApp.AgentRuntime.as("maria")
```

- Every operation takes a scope. `MyApp.AgentRuntime.as/2` is `Wardrik.as/3`.
- See [Who may do what](access.md) for a real authorizer.

## Configure it

Each place overrides the one before it:

```elixir
# 1. config/runtime.exs
config :my_app, MyApp.AgentRuntime,
  authorizer: {MyApp.Authorizer, []},
  resolver: {MyApp.Agents, []},
  store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"}

# 2. The supervision tree
children = [{MyApp.AgentRuntime, deployment: "production"}]

# 3. init/1, for what's only known at runtime
defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app

  @impl Wardrik
  def init(config), do: {:ok, Keyword.put(config, :vault_keys, [System.fetch_env!("WARDRIK_KEY")])}
end
```

See `Wardrik.start_link/1` for every option.

## Stores

In memory unless `:store` is set, and gone when Wardrik stops.

```elixir
# On disk
store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"}

# In your app's Postgres. Create the table with WardrikStore.Ecto.Migration.
store: {WardrikStore.Ecto, repo: MyApp.Repo}

# In a Postgres of its own, which migrates itself
store: {WardrikStore.Ecto, url: "postgres://user:pass@db.example.com/my_app"}
```

- `WardrikStore.Ecto` needs `:ecto_sql` and `:postgrex` in your deps.
- To share a store with your app, build it and give it to both. The second to start it leaves it be:

```elixir
store = WardrikStore.EKV.new(name: MyApp.Store, data_dir: "/var/lib/my_app")

children = [{MyApp.AgentRuntime, store: store}, {WardrikStore, store}]
```

## Model calls

`:model_options` applies to every agent's model calls. `:pool` sizes the connections they share.

```elixir
config :my_app, MyApp.AgentRuntime,
  model_options: [temperature: 0.2, receive_timeout: :timer.minutes(10)],
  pool: [size: 128, protocols: [:http2]]
```

- `:model_options` takes any `ReqLLM` option. An agent's own `model_options` merge over it.
- A definition's `model_options` take only `temperature`, `top_p`, `max_tokens`,
  `reasoning_effort` and the call's timeouts. Each call carries the provider's API key, so options
  that change where a call goes, such as `base_url`, are set only in Wardrik's options.
- `:pool` is one `Finch` pool per provider host: 64 HTTP/1 connections by default. Raise it when
  many agents call one provider at once.
- The pool is sized at start. Option changes apply from each agent's next turn.

## Nodes

Each agent runs on one node at a time. Any node reaches it.

```elixir
{:ok, _} = Wardrik.Agent.define(scope, "agt_assistant", model: "anthropic:claude-haiku-4-5")

Wardrik.Deployment.nodes(scope)
#=> {:ok, %Wardrik.Nodes{nodes: [%Wardrik.Node{name: "nonode@nohost", agents: 1}], asleep: 0}}

# Move an agent. Its current turn ends, so ask it again after.
Wardrik.Agent.move(scope, "agt_assistant", node: "wardrik@box2")

# Every agent takes its definition as it reads now. Returns the nodes reached.
Wardrik.Deployment.reload(scope)
#=> {:ok, ["nonode@nohost"]}
```

In IEx, `move` returns `invalid_request`: there's no `wardrik@box2`.

## Agents started in code

Most agents are defined as data; see [Define agents](definitions.md). To start one with your own
modules:

```elixir
defmodule MyApp.Books do
  @behaviour WardrikCore.Capability

  @impl true
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "pay_bill",
        description: "Pays a bill.",
        schema: [bill_id: [type: :string, required: true]],
        run: fn %{bill_id: id}, _context -> {:ok, "Paid #{id}."} end
      )
    ]
  end
end

Wardrik.start_agent(MyApp.AgentRuntime,
  agent_id: "agt_books",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [MyApp.Books],
  policy: [ask: ["pay_bill"]]
)
#=> {:ok, #PID<0.938.0>}
```

- It takes what `WardrikCore.start_agent/2` takes, plus `:policy`.
- The agent is held to its own policy, the one your resolver gives it, and Wardrik's `:policy`.
- It runs until you stop it.
