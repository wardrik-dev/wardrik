# A store in Postgres

A [Wardrik store](../../wardrik_core/guides/store.md) in Postgres, through an Ecto repo your
application owns. Agents, their events, triggers and sealed credentials are
kept in one table, `wardrik_records`.

`:ecto_sql` and `:postgrex` are optional: an application with a repo has
them already, and one that keeps the store elsewhere compiles neither.

An application embedding Wardrik has it already. It names the repo as its
store, and starts the store and Wardrik after its repo:

```elixir
store = Wardrik.store(repo: MyApp.Repo)

children = [
  MyApp.Repo,
  {WardrikStore, store},
  {Wardrik, Wardrik.new(store: store)},
  MyAppWeb.Endpoint
]
```

A host that puts its own tree together names the adapter:

```elixir
store = WardrikStore.new(adapter: WardrikEcto.Store, repo: MyApp.Repo)

children = [
  MyApp.Repo,
  {WardrikStore, store},
  {Wardrik.Core, host: Wardrik.Host.new(store: store)},
  MyAppWeb.Endpoint
]
```

Create the table from a migration of your own:

```elixir
defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: WardrikEcto.Migration.up(version: 1)
  def down, do: WardrikEcto.Migration.down(version: 1)
end
```

Its reads are current on every node, so it holds the fleet too: a new node
pointed at the same database carries on with the agents of one that is gone.
