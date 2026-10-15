---
title: Embed in your app
description: "Run Wardrik inside your own Elixir application, kept in your Postgres, started in your supervision tree."
sidebar:
  order: 4.5
---

Wardrik is a set of Elixir libraries, so an Elixir application can run agents itself instead of
talking to a daemon. Your app keeps Wardrik in its own database and starts it in its own tree. You
decide who may do what, and your code calls operations directly.

This guide adds Wardrik to a Phoenix app with a Postgres `Repo`, then the parts you choose: budgets,
triggers, the HTTP API and sign-ins to other services.

## 1. Add the packages

Depend on the packages you use by path, from a checkout of Wardrik beside your app or a git
submodule in it. Each one finds the packages it needs beside it, so list only your own:

```elixir title="mix.exs"
defp deps do
  wardrik = System.get_env("WARDRIK_PATH", "vendor/wardrik")

  [
    {:wardrik, path: "#{wardrik}/packages/wardrik"},
    {:wardrik_ecto, path: "#{wardrik}/packages/wardrik_ecto"},
    {:wardrik_policy, path: "#{wardrik}/packages/wardrik_policy"},
    {:wardrik_trigger, path: "#{wardrik}/packages/wardrik_trigger"}
    # ...
  ]
end
```

`WARDRIK_PATH` is your app's own setting: point it at another checkout while you work on Wardrik
itself.

## 2. Create its table

Wardrik keeps everything in one table. Create it from a migration of your own:

```elixir title="priv/repo/migrations/20260926000000_add_wardrik.exs"
defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: WardrikEcto.Migration.up(version: 1)
  def down, do: WardrikEcto.Migration.down(version: 1)
end
```

[Storage](/run/storage/#postgres) says what goes in it.

## 3. Build the host

Tell Wardrik your app starts it:

```elixir title="config/config.exs"
config :wardrik, start: :host
```

Then build a `Wardrik.Host`: the store, and a value for each seam you offer. A seam you leave out
answers that it isn't supported.

```elixir title="lib/my_app/agents.ex"
defmodule MyApp.Agents do
  def store, do: WardrikStore.new(adapter: WardrikEcto.Store, repo: MyApp.Repo)

  def host do
    Wardrik.Host.new(store: store(), grants: %MyApp.Grants{})
  end
end
```

`grants` answers what each person may do. Your sign-in decides who they are; see `Wardrik.Grants`.

## 4. Start it in your tree

Start Wardrik after your `Repo`, then what runs on it. A line you leave out is a part you don't run:

```elixir title="lib/my_app/application.ex"
store = MyApp.Agents.store()
host = MyApp.Agents.host()

wardrik = [
  {WardrikStore, store},
  {Wardrik, host: host},
  {WardrikPolicy.Supervisor, store: store},
  {WardrikTrigger, store: store}
]

children = [MyApp.Repo] ++ wardrik ++ [MyAppWeb.Endpoint]
Supervisor.start_link(children, strategy: :rest_for_one, name: MyApp.Supervisor)
```

| Child | What it runs |
| --- | --- |
| `WardrikStore` | the store, in your `Repo` |
| `Wardrik` | the agents |
| `WardrikPolicy.Supervisor` | the meters [budgets](/concepts/budgets/) count in |
| `WardrikTrigger` | [triggers](/build/triggers/): clocks, feeds and webhooks |

Under `:rest_for_one`, a restart of one restarts everything after it, so the parts always run on
the Wardrik before them.

## 5. Run operations

Your code acts on agents through the same operations the HTTP API runs, as a caller your grants
know:

```elixir
id = Wardrik.AgentID.new!("support", org: "acme")
{:ok, caller} = Wardrik.Host.caller(host, principal: maria, subject: id)
Wardrik.Query.run(%Wardrik.Operations.ReadAgent{agent: id}, caller)
```

Each one checks the caller's grant and records what it changed in the audit log.

## Serve the HTTP API

To let other programs reach your agents, such as the TypeScript SDK, start the API's listener on a
port of its own, and have your proxy forward `/v1/` to it:

```elixir
wardrik ++
  [
    {WardrikHTTP.Access, store: store},
    WardrikHTTP.Workers,
    {WardrikHTTP.Listener, host: host, port: 4850, authenticator: %MyApp.Session{}}
  ]
```

The listener knows each request by its `authenticator`, a struct implementing
`WardrikHTTP.Authenticator`. Without one, requests present tokens made with `WardrikHTTP.Token`. The
[HTTP API guide](/build/http-api/) is every route.

## Let people connect accounts

To have tools sign people in to other services, keep their tokens in a vault that grants through
`WardrikOAuth`, offer both on the host, and start its supervisor:

```elixir
oauth = WardrikOAuth.new(client: [name: "My app"], providers: providers, redirect: [url: url])
vault = WardrikVault.new(store: store, keys: keys, grants: oauth)
connections = %WardrikOAuth.Connections{oauth: oauth, vault: vault}

host = Wardrik.Host.new(store: store, credentials: vault, connections: connections)
# after {Wardrik, host: host}:
{WardrikOAuth.Supervisor, oauth: oauth}
```

[Connect accounts](/build/accounts/) is how people sign in.

## Details

### One Wardrik per node

Wardrik's own processes are registered under their module names, so a node runs one. To run
several on one machine, run several nodes.

### Logs

`DurableServer` logs each agent it starts and moves. Quiet it in your application's `start/2`:

```elixir
Logger.put_application_level(:durable_server, :warning)
```

### System monitoring

`DurableServer` starts `:os_mon`, whose port programs report the machine's load. Where you don't
want them running, turn them off:

```elixir title="config/config.exs"
config :os_mon, start_cpu_sup: false, start_disksup: false, start_memsup: false
```

### Many agents at once

Each turn streams from its model. With many agents answering at once, raise the stream pool:

```elixir title="config/runtime.exs"
config :req_llm, stream_pool_count: 128
```
