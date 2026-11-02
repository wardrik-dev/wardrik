# WardrikStore

A durable key-value store. Wardrik packages keep their data in it, and
[WardrikCore](https://hexdocs.pm/wardrik_core) can keep its agents in it too.

## Install

```elixir
def deps do
  [
    {:wardrik_store, "~> 0.1.0-rc.1"}
  ]
end
```

## Start a store

```elixir
store = WardrikStore.ETS.new(name: MyApp.Store)
children = [{WardrikStore, store}]
```

A store that's already running starts nothing, so each package that uses it can list it too.

| Adapter | Keeps data | Needs |
| --- | --- | --- |
| `WardrikStore.ETS` | In memory. For tests and data you can rebuild | Nothing |
| `WardrikStore.EKV` | On disk, on each connected node | `{:ekv, "~> 0.4"}` |
| `WardrikStore.Ecto` | In Postgres | `{:ecto_sql, "~> 3.13"}`, and `:postgrex` for `:url` |

```elixir
store = WardrikStore.EKV.new(name: MyApp.Store, data_dir: "/var/lib/my_app")
store = WardrikStore.Ecto.new(repo: MyApp.Repo)
store = WardrikStore.Ecto.new(url: "postgres://user:pass@db.example.com/wardrik?ssl=true")
```

With your own repo, create the table in a migration:

```elixir
defmodule MyApp.Repo.Migrations.AddWardrikStore do
  use Ecto.Migration

  def up, do: WardrikStore.Ecto.Migration.up(version: 1)
  def down, do: WardrikStore.Ecto.Migration.down(version: 1)
end
```

- Point the repo at the primary, not a replica.
- With `:url`, the store starts its own repo and creates the table itself.

## Read and write

```elixir
mine = WardrikStore.scope(store, "my_app")

{:ok, vsn} = WardrikStore.put(mine, "settings/theme", "dark", if_vsn: nil)

WardrikStore.get(mine, "settings/theme")
#=> "dark"

WardrikStore.keys(mine, "settings/")
#=> ["settings/theme"]

{:ok, _vsn} = WardrikStore.put(mine, "settings/theme", "light", if_vsn: vsn)

WardrikStore.put(mine, "settings/theme", "blue", if_vsn: vsn)
#=> {:error, :conflict}
```

- Each package scopes the store by its app name. Scope it yourself to keep your data apart.
- `:if_vsn` writes only over the version you read. `nil` writes only where nothing is.
- With EKV, once you write a key with `:if_vsn`, always write it that way.

## Keep agents in it

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

Implement `WardrikStore.Adapter`, plus a `new/1`:

```elixir
defmodule MyApp.Store do
  @behaviour WardrikStore.Adapter

  def new(opts), do: WardrikStore.new(__MODULE__, Keyword.fetch!(opts, :name))
end
```
