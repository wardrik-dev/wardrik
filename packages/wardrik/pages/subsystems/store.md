# Wardrik.Store

A durable key-value store. Wardrik packages keep their data in it, and
[WardrikCore](https://hexdocs.pm/wardrik_core) can keep its agents in it too.

## Start a store

Run in a fresh IEx session:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.10"}])

store = Wardrik.Store.ETS.new(name: MyApp.Store)
{:ok, _supervisor} = Supervisor.start_link([{Wardrik.Store, store}], strategy: :one_for_one)
```

A store that's already running starts nothing, so each package that uses it can list it too.

| Adapter | Keeps data | Needs |
| --- | --- | --- |
| `Wardrik.Store.ETS` | In memory. For tests and data you can rebuild | Nothing |
| `Wardrik.Store.EKV` | On disk, on each connected node | `{:ekv, "~> 0.4"}` |
| `Wardrik.Store.Ecto` | In Postgres | `{:ecto_sql, "~> 3.13"}`, and `:postgrex` for `:url` |
| `Wardrik.Store.S3` | In an S3 bucket: AWS, R2, Tigris or MinIO | `{:req, "~> 0.5"}` |

Adapter configuration and migrations are documented in `Wardrik.Store.EKV`, `Wardrik.Store.Ecto`, and `Wardrik.Store.S3`.

## Read and write

```elixir
mine = Wardrik.Store.scope(store, "my_app")

{:ok, vsn} = Wardrik.Store.put(mine, "settings/theme", "dark", if_vsn: nil)

Wardrik.Store.get(mine, "settings/theme")
# => "dark"

Wardrik.Store.keys(mine, "settings/")
# => ["settings/theme"]

{:ok, _vsn} = Wardrik.Store.put(mine, "settings/theme", "light", if_vsn: vsn)

Wardrik.Store.put(mine, "settings/theme", "blue", if_vsn: vsn)
# => {:error, :conflict}
```

- Each package scopes the store by its app name. Scope it yourself to keep your data apart.
- `:if_vsn` writes only over the version you read. `nil` writes only where nothing is.
- With EKV, once you write a key with `:if_vsn`, always write it that way.

## Keep agents in it

Application supervision fragment: configure `MyApp.Repo` as an Ecto repo before starting this alternative tree.

```elixir
store = Wardrik.Store.Ecto.new(repo: MyApp.Repo)

children = [
  MyApp.Repo,
  {Wardrik.Store, store},
  {WardrikCore, backend: {Wardrik.Store.Durable, store: store}}
]
```

Use it with Ecto or ETS. With EKV, use DurableServer's own `EKVStore` instead. It's faster.

## Write an adapter

Implement the callbacks in `Wardrik.Store.Adapter` and a `new/1` constructor returning a `Wardrik.Store` struct.
