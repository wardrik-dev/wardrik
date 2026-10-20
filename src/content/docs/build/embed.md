---
title: Embed in your app
description: "Run Wardrik inside your own Elixir application, kept in your Postgres, started in your supervision tree."
sidebar:
  order: 4.5
---

Wardrik is a set of Elixir libraries, so a Phoenix app can run agents itself. Your app keeps Wardrik
in its own database, starts it in its own tree, and decides what each of its users may do.

This guide builds one example from start to end. Its users are `%MyApp.Accounts.User{}` structs
with an `id`, an `org` and an `email`, as your own sign-in gives them. Each user gets agents of
their own. Then, if you want them, you add the HTTP API and let users connect their GitHub
accounts.

## 1. Add the package

```elixir title="mix.exs"
defp deps do
  [
    {:wardrik, "~> 0.1"}
    # ...
  ]
end
```

## 2. Create its table

Wardrik keeps everything in one table. Create it from a migration of your own:

```elixir title="priv/repo/migrations/20260926000000_add_wardrik.exs"
defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: Wardrik.Migration.up(version: 1)
  def down, do: Wardrik.Migration.down(version: 1)
end
```

[Storage](/run/storage/#postgres) says what goes in it.

## 3. Say who may do what

Wardrik knows a user as a `Wardrik.Principal`, named as the namespace they own things under, as
`acme/@42`, and asks your app for the token they act with. A token's statements each allow some
actions on some agents, and a role is a named set of actions. Here, a user may read and message
their org's agents, and own their own. Your app itself acts as the deployment, `deployment`, and
reads every agent's events:

```elixir title="lib/my_app/issuer.ex"
defmodule MyApp.Issuer do
  @moduledoc """
  The token each signed-in user acts with: reader and messenger on their
  org's agents, and owner of their own; and the app's own, as the
  deployment, reading every agent's events.
  """

  alias Wardrik.Resource
  alias Wardrik.Role

  defstruct []

  @doc "Who `user` is to Wardrik: a person in their org, as `acme/@42`."
  def principal(%MyApp.Accounts.User{} = user),
    do: Wardrik.Principal.new("#{user.org}/@#{user.id}", name: user.email)

  @doc "Who `user` is as an owner of accounts and agents: `acme/@42`."
  def own(%MyApp.Accounts.User{} = user), do: Resource.parse!("#{user.org}/@#{user.id}")

  @doc "What the user `id` of `org` may do."
  def scope(org, id) do
    [
      Role.bind([:reader, :messenger], [Resource.parse!("#{org}/agent/*")]),
      Role.bind([:owner], [Resource.parse!("#{org}/@#{id}/*")])
    ]
  end

  @doc "What the app itself reads, as the deployment: every agent's events, and where it stands."
  def deployment do
    [
      %Wardrik.Statement{
        actions: ["agent.events", "agent.read"],
        resources: [Resource.parse!("*/agent/*")]
      }
    ]
  end
end

defimpl Wardrik.Issuer, for: MyApp.Issuer do
  def issue(_issuer, principal, _opts) do
    case String.split(Wardrik.Principal.id(principal), "/") do
      ["deployment"] -> %Wardrik.Token{principal: principal, scope: MyApp.Issuer.deployment()}
      [org, "@" <> id] -> %Wardrik.Token{principal: principal, scope: MyApp.Issuer.scope(org, id)}
      _other -> %Wardrik.Token{principal: principal}
    end
  end
end
```

Maria, user 42 of `acme`, owns everything of `acme/@42`'s, such as the agent `acme/@42/support`,
whose resource is `acme/@42/agent/support`. A user of another org reaches none of them. [Agents](/concepts/agents/) explains IDs.

What follows agents' logs acts as `deployment`: [notices](/build/notices/) and a
[channel](/channels/)'s replies, which need `agent.events` on `*/agent/*` and fail without it, and
your own [listeners](/build/listen/), which read on from where they stopped.

A token your issuer issues expires after 12 hours, or as `Wardrik.new/1`'s
`expires: [session: seconds]` says. Each function of `Wardrik` refreshes one past that through your
issuer as it uses it, never wider than it was, so what you take away from a user holds at their
next call.

## 4. Describe Wardrik

`Wardrik.new/1` takes everything Wardrik needs from your app: the store in your `Repo`, and your
issuer. Keep it in one module:

```elixir title="lib/my_app/agents.ex"
defmodule MyApp.Agents do
  @moduledoc "Wardrik in this app: where it keeps everything, what runs, and what users do with agents."

  alias Wardrik.AgentID

  def store, do: Wardrik.store(repo: MyApp.Repo)

  def wardrik, do: Wardrik.new(store: store(), issuer: %MyApp.Issuer{})
end
```

Each agent's definition is kept in the store, and so are the files it works on. `tools:` names the
tools your app ships, which a definition names by name: `tools: [MyApp.Tools.Search]`. `context:`
says what else a definition may name, such as the policies it may hold to:
`context: Wardrik.context(policies: policies)`. A value of your own implementing
`WardrikDefinition.Contexts` gives each agent a context of its own, such as one per org.

To hold each org's agents to the allowance its plan pays for, give its context a policy with a
budget in `held`:

```elixir title="lib/my_app/contexts.ex"
defmodule MyApp.Contexts do
  @moduledoc "Each org's context: the base, holding its agents to the allowance it pays for."

  defstruct [:base]

  defimpl WardrikDefinition.Contexts do
    def context(%{base: base}, owner) do
      org = to_string(Wardrik.Resource.org(owner))
      budget = %{"usd" => MyApp.Billing.allowance_usd(org), "per" => "month"}
      %{base | held: base.held ++ [WardrikPolicy.decode!(%{"budget" => budget}, "allowance")]}
    end

    def reload(_contexts, _opts), do: []
  end
end
```

Pass it as `context: %MyApp.Contexts{base: Wardrik.context(policies: policies)}`. All of an org's
agents, its users' too, spend from one allowance together. An agent reads its owner's context as it
starts, so an allowance you change holds from its next start, or from `Wardrik.deployment_reload/1`.

`Wardrik.new/1` answers the `Wardrik.Host` everything runs on. A package adds what it brings to it
through an `attach/2` of its own, before Wardrik starts: its tools, what it serves over HTTP, and
what it runs, as `Wardrik.new(...) |> WardrikHTTP.attach(port: 4850)`. Wardrik starts what each
attached in the order they were attached.

## 5. Start it in your tree

List what runs, its store first, then start it after your `Repo`:

```elixir title="lib/my_app/agents.ex"
def children, do: [{WardrikStore, store()}, {Wardrik, wardrik()}]
```

```elixir title="lib/my_app/application.ex"
children =
  [MyAppWeb.Telemetry, MyApp.Repo] ++
    MyApp.Agents.children() ++
    [{Phoenix.PubSub, name: MyApp.PubSub}, MyAppWeb.Endpoint]

Supervisor.start_link(children, strategy: :rest_for_one, name: MyApp.Supervisor)
```

`{WardrikStore, ...}` keeps everything Wardrik keeps in your `Repo`, started as your `Repo` is.
`{Wardrik, ...}` runs, in order:

| Part | What it runs |
| --- | --- |
| The agents | the fleet, its event log and its audit log |
| The meters | what [budgets](/concepts/budgets/) count in |
| The triggers | [triggers](/build/triggers/): clocks, feeds and webhooks |
| The packages | what each package attached to it runs, in the order they were attached |

Under `:rest_for_one`, a restart of one restarts everything after it, so what you start after
Wardrik always runs on the Wardrik before it.

## 6. Define an agent and ask it

Your code acts as the signed-in user, in a scope `Wardrik.as/3` makes. Each function of
`Wardrik` checks their token, and records what it changed in the audit log:

```elixir title="lib/my_app/agents.ex"
def define(user, name, definition) do
  agent = AgentID.new!(name, org: user.org, user: to_string(user.id))
  Wardrik.agent_define(scope(user), agent, definition)
end

def ask(user, agent, text), do: Wardrik.agent_ask(scope(user), agent, text)

def subscribe(user, agent),
  do: Wardrik.subscribe(scope(user), resources: [AgentID.resource(agent)])

def events(user, agent, cursor),
  do:
    Wardrik.events(scope(user),
      resources: [AgentID.resource(agent)],
      after: cursor,
      follow: true
    )

defp scope(user), do: Wardrik.as(wardrik(), MyApp.Issuer.principal(user))
```

Define Maria's support agent, ask it something, and read the answer from its log. The model's key
is `ANTHROPIC_API_KEY` in your environment:

```elixir
maria = %MyApp.Accounts.User{id: 42, org: "acme", email: "maria@acme.example"}

{:ok, _snapshot} =
  MyApp.Agents.define(maria, "support", %{
    "model" => "anthropic:claude-sonnet-5",
    "instructions" => "Answer questions about orders in two sentences."
  })

agent = Wardrik.AgentID.new!("support", org: "acme", user: "42")
:ok = MyApp.Agents.subscribe(maria, agent)
{:ok, %Wardrik.Agent.Message{}} = MyApp.Agents.ask(maria, agent, "Where is order 1001?")

receive do
  %Wardrik.Event.Log.Entry{event: %{"type" => "wardrik.run.completed", "data" => data}} ->
    for %{"role" => "assistant", "parts" => parts} <- data["messages"],
        %{"type" => "text", "content" => text} <- parts,
        do: IO.puts(text)

  %Wardrik.Event.Log.Entry{event: %{"type" => "wardrik.run.failed", "data" => data}} ->
    IO.inspect(data["error"])
end
```

Every event an agent writes reaches its subscribers, so a LiveView can show a turn as it streams.
[Events](/concepts/events/) lists them. `resources:` takes patterns, as `acme/agent/*`, and
`types:` the event types to take. Nobody else reaches Maria's agent: reading `acme/agent/*`
reaches the org's own agents, not its users'. Anyone else is told it isn't there.

A subscription takes what is written from then on. To read what was written before, or to pick
up after a restart, read the log from a cursor. A message says where the log stood as it was
sent, so the turn that answers it comes after:

```elixir
{:ok, message} = MyApp.Agents.ask(maria, agent, "Where is order 1001?")
{:ok, events} = MyApp.Agents.events(maria, agent, message.cursor)

Enum.find(events, &(&1.event["type"] == "wardrik.run.completed"))
```

Wardrik keeps no reader's place. Keep your own: `Wardrik.cursor/2` moves a cursor past each entry,
and `events/2` reads on from it, then follows. A log trimmed past your cursor gives a
`wardrik.events.dropped` entry, and reading goes on from the oldest event it still holds.
[Follow events into your app](/build/listen/) keeps the place for you, in your own tables.

## Serve the HTTP API

To let other programs reach the agents, such as the TypeScript SDK, add `{:wardrik_http, "~> 0.1"}`.
The API knows each request by an authenticator of yours. This one reads a token your app gives
its user, signed with your endpoint's secret:

```elixir title="lib/my_app_web/session.ex"
defmodule MyAppWeb.Session do
  @moduledoc """
  Knows a request to the agents' API by a token this app gave its user,
  signed with the endpoint's secret.
  """

  @enforce_keys [:endpoint]
  defstruct [:endpoint]

  @doc "A token `user` presents as `Authorization: Bearer TOKEN`."
  def token(%MyApp.Accounts.User{} = user),
    do: Phoenix.Token.sign(MyAppWeb.Endpoint, "agents", user)
end

defimpl WardrikHTTP.Authenticator, for: MyAppWeb.Session do
  import Plug.Conn

  @day 86_400

  def authenticate(session, conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Phoenix.Token.verify(session.endpoint, "agents", token, max_age: @day) do
      token = %Wardrik.Token{
        principal: MyApp.Issuer.principal(user),
        scope: MyApp.Issuer.scope(user.org, to_string(user.id))
      }

      {:ok, %WardrikHTTP.Caller{id: "session/#{user.id}", name: user.email, token: token}}
    else
      _no_session -> {:error, :unauthorized}
    end
  end

  def challenge(_session), do: ~s(Bearer realm="my_app")
end
```

A request reaches the user's own agents, as its token says. Attach the API to Wardrik, which runs
its listener on a port of its own:

```elixir title="lib/my_app/agents.ex"
def wardrik do
  Wardrik.new(store: store(), issuer: %MyApp.Issuer{})
  |> WardrikHTTP.attach(
    port: 4850,
    authenticator: %MyAppWeb.Session{endpoint: MyAppWeb.Endpoint}
  )
end
```

`children/0` stays as it is. The API also offers your agents the tools of programs that connect to
it as [tool workers](/build/tool-workers/), which a definition names as `workers/*`.

Have your proxy forward `/v1/` to port 4850. Then Maria's programs list her agents with the token
your app gave her:

```sh
curl -H "Authorization: Bearer $TOKEN" https://myapp.example.com/v1/agents
```

The [HTTP API guide](/build/http-api/) is every route.

## Let people connect accounts

An agent can call GitHub's MCP server as the user it works for. Each user connects their own
GitHub account once, and their agents use it from then on. Add the packages:

```elixir title="mix.exs"
{:wardrik_oauth, "~> 0.1"},
{:wardrik_mcp, "~> 0.1"}
```

### Give it a key and a GitHub app

Tokens are kept in the store, sealed with a key you hold. Make one, and keep it as
`WARDRIK_VAULT_KEY` wherever the app runs:

```sh
mix run -e 'IO.puts(WardrikVault.generate_key())'
```

Register an OAuth app on GitHub. Its callback URL is your app's URL, then `/oauth/callback/github`,
such as `https://myapp.example.com/oauth/callback/github`. Set `MY_APP_URL`, `GITHUB_CLIENT_ID` and
`GITHUB_CLIENT_SECRET`.

### Offer the vault and the sign-in

The vault keeps each user's token in the store, and asks them to sign in where they have none. In
`MyApp.Agents`, `wardrik/0` becomes:

```elixir title="lib/my_app/agents.ex"
def wardrik do
  vault = vault()

  Wardrik.new(
    store: store(),
    issuer: %MyApp.Issuer{},
    credentials: vault,
    connections: %WardrikOAuth.Connections{oauth: oauth(), vault: vault}
  )
  |> WardrikMCP.attach(
    servers: [
      github: [
        transport: {:streamable_http, base_url: "https://api.githubcopilot.com/mcp/"},
        credential: "github"
      ]
    ]
  )
  |> Wardrik.Host.child({WardrikOAuth.Supervisor, []})
  |> WardrikHTTP.attach(
    port: 4850,
    authenticator: %MyAppWeb.Session{endpoint: MyAppWeb.Endpoint}
  )
end

def vault,
  do:
    WardrikVault.new(
      store: store(),
      keys: [System.fetch_env!("WARDRIK_VAULT_KEY")],
      grants: oauth()
    )

def oauth do
  WardrikOAuth.new(
    client: [name: "My app"],
    providers: [
      github: [
        resource: "https://api.githubcopilot.com/mcp/",
        issuer: "https://github.com/login/oauth",
        client_id: System.get_env("GITHUB_CLIENT_ID"),
        client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
        scopes: ~w(repo)
      ]
    ],
    redirect: [url: System.get_env("MY_APP_URL", "http://localhost:4000") <> "/oauth"]
  )
end
```

`WardrikMCP.attach/2` lets a definition name the server's tools as `github/*`, and runs its
connections, after Wardrik's own; `WardrikOAuth.Supervisor` runs the sign-ins under way.
`credential: "github"` makes each call with the token of the user the agent works for.

### Take GitHub's callback in your app

GitHub sends the browser back to your app, at the redirect URL above. Your router takes it:

```elixir title="lib/my_app_web/router.ex"
scope "/oauth", MyAppWeb do
  get "/callback/:provider", OAuthController, :callback
end
```

```elixir title="lib/my_app_web/controllers/oauth_controller.ex"
defmodule MyAppWeb.OAuthController do
  use MyAppWeb, :controller

  def callback(conn, %{"provider" => provider, "state" => state, "code" => code} = params) do
    case WardrikOAuth.finish(state, code, provider: provider, iss: params["iss"]) do
      {:ok, _provider} ->
        text(conn, "Connected. Go back to your agent.")

      {:error, _reason} ->
        conn |> put_status(400) |> text("That sign-in did not finish. Open its link again.")
    end
  end

  def callback(conn, _params),
    do: conn |> put_status(400) |> text("This is where a sign-in comes back to.")
end
```

### Connect, then use it

Add two functions to `MyApp.Agents`:

```elixir title="lib/my_app/agents.ex"
def connect(user, provider),
  do: Wardrik.connections_connect(scope(user), MyApp.Issuer.own(user), provider)

def connections(user), do: Wardrik.connections_list(scope(user), MyApp.Issuer.own(user))
```

Give Maria an agent that uses GitHub, and the link to connect her account:

```elixir
{:ok, _snapshot} =
  MyApp.Agents.define(maria, "triage", %{
    "model" => "anthropic:claude-sonnet-5",
    "instructions" => "Sort new issues in acme/shop by how urgent they are.",
    "tools" => ["github/*"]
  })

{:ok, %Wardrik.Connections.Connection{authorization: %{url: url}}} =
  MyApp.Agents.connect(maria, "github")
```

Show her `url`. She signs in at GitHub, comes back to `/oauth/callback/github`, and the vault keeps
her token. Her connections then say she holds it:

```elixir
{:ok, [%Wardrik.Connections.Connection{provider: "github", connected: true}]} =
  MyApp.Agents.connections(maria)
```

If her agent calls GitHub before she connects, the call waits. `connect/2` gives her a link, and
the call carries on once she signs in. GitHub's tools that change something wait for a
person to approve them; see [Approvals](/concepts/approvals/).

[Connect accounts](/build/accounts/) covers whose credentials a call uses.

## Details

### One Wardrik per node

Wardrik's own processes are registered under their module names, so a node runs one. To run
several on one machine, run several nodes.

### Keeping it elsewhere

`Wardrik.store/1` keeps everything in your `Repo` with `repo:`, in an S3 bucket with `bucket:`,
or on each node's disk with `data_dir:`, which needs `{:ekv, "~> 0.4.3"}` among your
dependencies. [Storage](/run/storage/) compares them.

### A new release

A release that writes agents differently needs no cleanup, and two releases running at once can't
read each other's agents. See [Upgrade and back up](/run/upgrade-and-back-up/#details).

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
