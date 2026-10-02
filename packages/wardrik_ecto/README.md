# wardrik_ecto

A [Wardrik](../wardrik) store in Postgres, through an Ecto repo your
application owns. Agents, their events, schedules and sealed credentials are
kept in one table, `wardrik_records`.

```elixir
def deps do
  [{:wardrik_ecto, "~> 0.1.0"}]
end
```

Start Wardrik after your repo, and name the repo as its store:

```elixir
# config/config.exs
config :wardrik, start: :host
config :wardrik, Wardrik.Store, adapter: WardrikEcto.Store, repo: MyApp.Repo

# lib/my_app/application.ex
children = [MyApp.Repo, Wardrik, MyAppWeb.Endpoint]
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
