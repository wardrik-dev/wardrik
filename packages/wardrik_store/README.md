# WardrikStore

A durable key-value store. Wardrik packages keep their data in it, and
[WardrikCore](https://hexdocs.pm/wardrik_core) can keep its agents in it too.

## Install

```elixir
def deps do
  [
    {:wardrik_store, "~> 0.1.0-rc.5"}
  ]
end
```

## Start a store

Run in a fresh IEx session:

```elixir
Mix.install([{:wardrik_store, "~> 0.1.0-rc.5"}])

store = WardrikStore.ETS.new(name: MyApp.Store)
{:ok, _supervisor} = Supervisor.start_link([{WardrikStore, store}], strategy: :one_for_one)
```

A store that's already running starts nothing, so each package that uses it can list it too.

| Adapter | Keeps data | Needs |
| --- | --- | --- |
| `WardrikStore.ETS` | In memory. For tests and data you can rebuild | Nothing |
| `WardrikStore.EKV` | On disk, on each connected node | `{:ekv, "~> 0.4"}` |
| `WardrikStore.Ecto` | In Postgres | `{:ecto_sql, "~> 3.13"}`, and `:postgrex` for `:url` |
| `WardrikStore.S3` | In an S3 bucket: AWS, R2, Tigris or MinIO | `{:req, "~> 0.5"}` |

Adapter configuration and migrations are documented in `WardrikStore.EKV`, `WardrikStore.Ecto`, and `WardrikStore.S3`.

## Read and write

```elixir
mine = WardrikStore.scope(store, "my_app")

{:ok, vsn} = WardrikStore.put(mine, "settings/theme", "dark", if_vsn: nil)

WardrikStore.get(mine, "settings/theme")
# => "dark"

WardrikStore.keys(mine, "settings/")
# => ["settings/theme"]

{:ok, _vsn} = WardrikStore.put(mine, "settings/theme", "light", if_vsn: vsn)

WardrikStore.put(mine, "settings/theme", "blue", if_vsn: vsn)
# => {:error, :conflict}
```

- Each package scopes the store by its app name. Scope it yourself to keep your data apart.
- `:if_vsn` writes only over the version you read. `nil` writes only where nothing is.
- With EKV, once you write a key with `:if_vsn`, always write it that way.

## Keep agents in it

Application supervision fragment: configure `MyApp.Repo` as an Ecto repo before starting this alternative tree.

```elixir
store = WardrikStore.Ecto.new(repo: MyApp.Repo)

children = [
  MyApp.Repo,
  {WardrikStore, store},
  {WardrikCore, backend: {WardrikStore.Durable, store: store}}
]
```

Use it with Ecto or ETS. With EKV, use DurableServer's own `EKVStore` instead. It's faster.

## Write an adapter

Implement the callbacks in `WardrikStore.Adapter` and a `new/1` constructor returning a `WardrikStore` struct.
