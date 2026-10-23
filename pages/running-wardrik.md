# Run Wardrik

One `Wardrik` runs your agents, keeps what they do, and holds them to your policies.

## Start it

```elixir
wardrik = Wardrik.new(name: MyApp.Wardrik, data_dir: "/var/lib/my_app", deployment: "acme-prod")

children = [{Wardrik, wardrik}]
```

| Key | Takes | Unless set |
| --- | --- | --- |
| `name` | the name Wardrik runs by | required |
| `data_dir` | the directory agents and their events are kept in | in memory |
| `deployment` | the deployment's name, in each event's `source` | `"local"` |
| `policy` | the policy every agent is held to | none |
| `authorizer` | a `Wardrik.Authorizer` as `{module, config}` | `{Wardrik.Statements, []}` |
| `retention` | the days events are kept, or `:infinity` | 30 |
| `store` | a `WardrikStore` you run yourself, in place of `data_dir` | none |
| `backend` | where agents are kept, if not with their events | with their events |

## Where agents are kept

Given a `data_dir`, Wardrik keeps agents and their events on disk there, and on each node when
clustered. Given neither a `data_dir` nor a `store`, it keeps them in memory, and they're gone when
it stops. Reach for that in development and tests.

To keep them somewhere else, like Postgres, run a [WardrikStore](https://hexdocs.pm/wardrik_store)
yourself and give it as `store`. Wardrik starts the store it builds, and leaves one you give it to
you.

## Start an agent

```elixir
Wardrik.start_agent(wardrik,
  agent_id: "acme/books",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [MyApp.Books],
  policy: [ask: ["books/pay_bill"]]
)
```

It takes what `WardrikCore.start_agent/2` takes, and `policy`, the agent's own. See
[Policies](policies.md).
