# Run Wardrik

One Wardrik runs your agents, keeps what they do, and holds them to your policies. Make it a module
of your app:

```elixir
defmodule MyApp.Wardrik do
  use Wardrik, otp_app: :my_app
end
```

Add it to your supervision tree, ahead of anything that uses it:

```elixir
children = [MyApp.Wardrik]
```

Everything else names it: `MyApp.Wardrik.as/2` makes a scope, and every operation takes one.

## Configure it

It reads `config :my_app, MyApp.Wardrik`, then the options it's started with, as
`{MyApp.Wardrik, deployment: "acme-prod"}`, then its `init/1`, for what's only known as it runs:

```elixir
defmodule MyApp.Wardrik do
  use Wardrik, otp_app: :my_app

  @impl Wardrik
  def init(config), do: {:ok, Keyword.put(config, :keys, [System.fetch_env!("WARDRIK_KEY")])}
end
```

Each test can start it as it starts in production, or point it elsewhere in `config/test.exs`.

| Key | Takes | Unless set |
| --- | --- | --- |
| `data_dir` | the directory agents and their events are kept in | in memory |
| `deployment` | the deployment's name, in each event's `source` | `"local"` |
| `policy` | the policy every agent is held to; see [Policies](policies.md) | none |
| `keys` | the keys credentials are sealed with; see [Credentials](credentials.md) | none |
| `oauth` | the services people sign in to; see [Credentials](credentials.md) | none |
| `mcp` | the MCP servers it starts with; see [MCP servers](servers.md) | none |
| `capabilities`, `policies`, `middleware`, `idle_timeout` | what definitions name; see [Define agents](definitions.md) | none |
| `listeners` | the listeners it starts; see [Events](events.md) | none |
| `triggers` | `req_options` for reading feeds; see [Trigger agents](triggers.md) | none |
| `authorizer` | a `Wardrik.Authorizer` as `{module, config}`; see [Who may do what](access.md) | statements |
| `retention` | the days events are kept, or `:infinity` | 30 |
| `store` | a `WardrikStore` you run yourself, in place of `data_dir` | none |

These are set as it starts. What changes as it runs, like agents, triggers, servers, accounts and
tokens, goes through its operations, kept in its store for every node.

## Where agents are kept

Given a `data_dir`, it keeps agents and their events on disk there, and on each node when
clustered. Given neither a `data_dir` nor a `store`, it keeps them in memory, gone when it stops:
reach for that in development and tests. To keep them somewhere else, like Postgres, run a
[WardrikStore](https://hexdocs.pm/wardrik_store) yourself and give it as `store`.

## Nodes

In a cluster, each agent runs on one node at a time, and any node reaches it:

```elixir
{:ok, %Wardrik.Nodes{nodes: [%Wardrik.Node{name: name, agents: count} | _rest], asleep: asleep}} =
  Wardrik.Deployment.nodes(scope)

{:ok, %Wardrik.Agent{node: ^name}} = Wardrik.Agent.move(scope, "acme/triage", node: name)
```

Moving an agent ends a turn it's taking, and abandons what it waits on. `Wardrik.Deployment.reload/1`
has every agent take its definition as it reads now.

## Agents started in code

Most agents are defined, as data; see [Define agents](definitions.md). To start one from code
instead, with modules of your own:

```elixir
Wardrik.start_agent(MyApp.Wardrik,
  agent_id: "acme/books",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [MyApp.Books],
  policy: [ask: ["books/pay_bill"]]
)
```

It takes what `WardrikCore.start_agent/2` takes, and `policy`, the agent's own. An agent started
this way runs until you stop it.
