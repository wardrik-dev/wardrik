# wardrik

Agents inside your Elixir application: kept in its own store, started as one
child of its tree, and reached as the people it knows.

```elixir
def deps do
  [{:wardrik, "~> 0.1.0"}]
end
```

Describe Wardrik once, start it after your repo, and make each user's caller
with it:

```elixir
wardrik = Wardrik.new(store: Wardrik.store(repo: MyApp.Repo), grants: %MyApp.Grants{})

children = [MyApp.Repo, {Wardrik, wardrik}, MyAppWeb.Endpoint]

{:ok, caller} = Wardrik.caller(wardrik, principal: maria, subject: agent)
Wardrik.Command.run(%Wardrik.Operations.Define{agent: agent, definition: definition}, caller)
```

Create its table from a migration of your own:

```elixir
defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: Wardrik.Migration.up(version: 1)
  def down, do: Wardrik.Migration.down(version: 1)
end
```

`{Wardrik, wardrik}` starts the store, [core](../wardrik_core), the meters
[budgets](../wardrik_policy) count in, and [triggers](../wardrik_trigger), in
that order. Each agent's definition is kept in the store, read by
[wardrik_definition](../wardrik_definition) against what `context:` lets it
name, and so are the files it works on.

`Wardrik.store/1` keeps everything in Postgres through your repo (`repo:`), in
an S3 bucket (`bucket:`), or on each node's disk (`data_dir:`, with
`{:ekv, "~> 0.4.3"}` among your dependencies).

The [embedding guide](https://docs.wardrik.dev/build/embed/) builds a Phoenix
app on it, with the HTTP API and accounts people connect.
