# Run Wardrik

> See it in action: [Agents that survive a crash](../notebooks/durability-demo.livemd)

Wardrik runs your agents, keeps what they do, and holds them to your policies. Make it a module of
your app:

```elixir
defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app
end
```

In your app, add it to your supervision tree, ahead of anything that uses it:

```elixir
children = [MyApp.AgentRuntime]
```

To try it, paste the module into a fresh IEx session started with
`Mix.install([{:wardrik, "~> 0.1.0-rc.1"}])`, then start it and act as someone:

```elixir
{:ok, _} = MyApp.AgentRuntime.start_link()

scope =
  MyApp.AgentRuntime.as("acme/@maria", roles: [:owner], resources: ["acme/@maria/*", "deployment"])
```

Every operation takes a scope. `MyApp.AgentRuntime.as/2` is `Wardrik.as/3` with the instance filled in.

## Configure it

Each place overrides the one before it:

```elixir
# 1. config/runtime.exs
config :my_app, MyApp.AgentRuntime, store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"}

# 2. The supervision tree
children = [{MyApp.AgentRuntime, deployment: "acme-prod"}]

# 3. init/1, for what's only known at runtime
defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app

  @impl Wardrik
  def init(config), do: {:ok, Keyword.put(config, :keys, [System.fetch_env!("WARDRIK_KEY")])}
end
```

Tests can start it as production does, or point it elsewhere in `config/test.exs`.

## Options

  * `:store` - where agents and their events are kept, as `{adapter, opts}`. In memory unless set.
    See [Where agents are kept](#where-agents-are-kept).
  * `:deployment` - the deployment's name in each event's `source`. `"local"` unless set.
  * `:policy` - the policy every agent is held to. See [Policies](policies.md).
  * `:keys` - keys to seal credentials with. See [Credentials](credentials.md).
  * `:oauth` - services people sign in to. See [Credentials](credentials.md).
  * `:mcp` - MCP servers to start with. See [MCP servers](servers.md).
  * `:capabilities`, `:policies`, `:middleware`, `:idle_timeout` - what definitions name. See
    [Define agents](definitions.md).
  * `:listeners` - listeners to start. See [Events](events.md).
  * `:triggers` - `req_options` for reading feeds. See [Trigger agents](triggers.md).
  * `:authorizer` - a `Wardrik.Authorizer`, as `{module, config}`. Statements unless set. See
    [Who may do what](access.md).
  * `:retention` - days events are kept, or `:infinity`. `30` unless set.

See `Wardrik.start_link/1` for every option.

Options are read as Wardrik starts. What changes while it runs, like agents, triggers, servers,
accounts and tokens, goes through operations, and is kept in the store for every node.

## Where agents are kept

In memory unless `:store` is set, and gone when Wardrik stops. That suits development and tests.

```elixir
# On disk
config :my_app, MyApp.AgentRuntime, store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"}

# In your app's Postgres; create the table with WardrikStore.Ecto.Migration
config :my_app, MyApp.AgentRuntime, store: {WardrikStore.Ecto, repo: MyApp.Repo}

# In a Postgres of its own, which migrates itself
config :my_app, MyApp.AgentRuntime,
  store: {WardrikStore.Ecto, url: "postgres://user:pass@db.example.com/my_app"}
```

`WardrikStore.Ecto` needs `:ecto_sql` and `:postgrex` in your deps.

To share the store with the rest of your app, build it and give it to both. Whichever starts it
second finds it running and leaves it be:

```elixir
store = WardrikStore.EKV.new(name: MyApp.Store, data_dir: "/var/lib/my_app")

children = [
  {MyApp.AgentRuntime, store: store},
  {WardrikStore, store}
]
```

## Nodes

In a cluster, each agent runs on one node at a time, and any node reaches it. Define an agent, then
list the nodes:

```elixir
{:ok, _} =
  Wardrik.Agent.define(scope, "acme/@maria/assistant", model: "anthropic:claude-haiku-4-5")

Wardrik.Deployment.nodes(scope)
#=> {:ok,
#=>  %Wardrik.Nodes{
#=>    nodes: [%Wardrik.Node{name: "nonode@nohost", agents: 1}],
#=>    asleep: 0
#=>  }}
```

In a cluster, the list has every node, as `"wardrik@box1"` and `"wardrik@box2"`. Move an agent
to another node by its name:

```elixir
Wardrik.Agent.move(scope, "acme/@maria/assistant", node: "wardrik@box2")
#=> {:ok, %Wardrik.Agent{id: "acme/@maria/assistant", status: :idle, node: "wardrik@box2", ...}}
```

In a single IEx session, that returns `invalid_request`: there's no `wardrik@box2`. Moving an
agent ends the turn it's taking and abandons what it waits on, so ask it again once it's moved.

`Wardrik.Deployment.reload/2` has every agent take its definition as it reads now. Awake agents
take it from their next turn, and sleeping ones as they wake. It returns the nodes it reached:

```elixir
Wardrik.Deployment.reload(scope)
#=> {:ok, ["nonode@nohost"]}
```

## Agents started in code

Most agents are defined as data; see [Define agents](definitions.md). To start one from code, with
modules of your own:

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
  agent_id: "acme/@maria/books",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [MyApp.Books],
  policy: [ask: ["pay_bill"]]
)
#=> {:ok, #PID<0.938.0>}
```

It takes what `WardrikCore.start_agent/2` takes, plus `:policy`, the agent's own. The agent is held
to its own policy, its org's and the deployment's. It runs until you stop it.
