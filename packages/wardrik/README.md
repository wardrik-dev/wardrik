# wardrik

Agents inside your Elixir application: kept in its own store, started as one
child of its tree, and reached as the people it knows.

```elixir
def deps do
  [{:wardrik, "~> 0.1.0"}]
end
```

Describe Wardrik once, start its store and it after your repo, and act on
the agents as each user, in a scope:

```elixir
store = Wardrik.store(repo: MyApp.Repo)
wardrik = Wardrik.new(store: store, issuer: %MyApp.Issuer{}, tools: [MyApp.Tools.Search])

children = [MyApp.Repo, {WardrikStore, store}, {Wardrik, wardrik}, MyAppWeb.Endpoint]

scope = Wardrik.as(wardrik, maria)
{:ok, _snapshot} = Wardrik.agent_define(scope, agent, definition)
{:ok, message} = Wardrik.agent_ask(scope, agent, "Where is order 1001?")
```

A scope holds a token, which says who acts and what they may do: its
statements each allow some actions, such as `agent.ask`, on the resources
a pattern covers, as `acme/agent/*`, and anything none allows is denied. A role is a named set
of actions: `reader`, `messenger`, `approver`, `definer`, `worker` and
`owner`. Your `Wardrik.Issuer` issues each user their token.

Create its table from a migration of your own:

```elixir
defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: Wardrik.Migration.up(version: 1)
  def down, do: Wardrik.Migration.down(version: 1)
end
```

`{WardrikStore, store}` starts the store, as your repo starts.
`{Wardrik, wardrik}` starts [core](../wardrik_core), the meters
[budgets](guides/policy.md) count in, [triggers](guides/triggers.md), then
what the packages attached to it add, in that order. Each agent's definition
is kept in the store, read as [definitions](guides/definition.md) are
against the tools `tools:` names and what `context:` lets it name, and so
are [the files](guides/workspace.md) it works on. `Wardrik.context/1` makes
one context for every agent; a value of your own implementing
`WardrikDefinition.Contexts` gives each agent its own.

A package adds its tools, and what it runs, to the `Wardrik.Host`
`Wardrik.new/1` answers, through an `attach/2` of its own, before Wardrik
starts: `Wardrik.new(store: store) |> SomePackage.attach()`.

`Wardrik.store/1` keeps everything in Postgres through your repo (`repo:`), in
an S3 bucket (`bucket:`), or on each node's disk (`data_dir:`, with
`{:ekv, "~> 0.4.3"}` among your dependencies).

The [embedding guide](https://docs.wardrik.dev/build/embed/) builds a Phoenix
app on it, with the HTTP API and accounts people connect.

## Guides

What it holds beside the `Wardrik` API, each with a guide of its own:
[definitions](guides/definition.md), [policies](guides/policy.md) and the
rules they write ([reference](guides/policies.md)),
[triggers](guides/triggers.md), [files](guides/workspace.md),
[the vault](guides/vault.md), [notices](guides/notify.md), stores in
[Postgres](guides/postgres.md) and [S3](guides/s3.md),
[workflows](guides/workflow.md) and [deep research](guides/research.md).
