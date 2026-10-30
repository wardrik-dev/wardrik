---
title: Embed in your app
description: "Run Wardrik inside your own Elixir application, kept in your Postgres, started in your supervision tree."
sidebar:
  order: 4.5
---

Sometimes you want agents in the app you already have, not in a service beside it. Let's add
Wardrik to a Phoenix app. It keeps its data in your Postgres, starts in your supervision tree, and
your app decides what each user may do.

We'll build one example from start to finish. Users are `%MyApp.Accounts.User{}` structs with an
`id`, an `org` and an `email`, the way your sign-in already hands them over. Each user gets agents
of their own. At the end, if you want them, we'll add the HTTP API, let users connect their GitHub
accounts, and answer in Slack.

## 1. Add the package

```elixir title="mix.exs"
defp deps do
  [
    {:wardrik, "~> 0.1.0-rc.1"}
    # ...
  ]
end
```

A Phoenix app already has `:ecto_sql` and `:postgrex`, which the Postgres store needs.

## 2. Create its table

Wardrik keeps everything in one table. Create it from a migration of your own:

```elixir title="priv/repo/migrations/20260926000000_add_wardrik.exs"
defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: WardrikStore.Ecto.Migration.up(version: 1)
  def down, do: WardrikStore.Ecto.Migration.down(version: 1)
end
```

When a release adds a version, add a migration that runs it. [Storage](/run/storage/) says what
goes in the table.

## 3. Start it in your tree

Make Wardrik a module of your app:

```elixir title="lib/my_app/wardrik.ex"
defmodule MyApp.Wardrik do
  use Wardrik, otp_app: :my_app
end
```

Point it at your `Repo`:

```elixir title="config/config.exs"
config :my_app, MyApp.Wardrik, store: {WardrikStore.Ecto, repo: MyApp.Repo}
```

Start it after your `Repo`, and before anything that uses it:

```elixir title="lib/my_app/application.ex"
children = [
  MyAppWeb.Telemetry,
  MyApp.Repo,
  MyApp.Wardrik,
  {Phoenix.PubSub, name: MyApp.PubSub},
  MyAppWeb.Endpoint
]

Supervisor.start_link(children, strategy: :rest_for_one, name: MyApp.Supervisor)
```

Notice `:rest_for_one`. A restart of `MyApp.Wardrik` restarts what comes after it, so your endpoint
never runs against a Wardrik that went away.

Options come from three places. Each overrides the one before:

```elixir
# 1. config/config.exs or config/runtime.exs
config :my_app, MyApp.Wardrik, store: {WardrikStore.Ecto, repo: MyApp.Repo}

# 2. The supervision tree
children = [{MyApp.Wardrik, deployment: "production"}]

# 3. init/1 in MyApp.Wardrik, for what's only known at runtime
@impl Wardrik
def init(config), do: {:ok, Keyword.put(config, :keys, [System.fetch_env!("WARDRIK_KEY")])}
```

`Wardrik.start_link/1` lists every option.

## 4. Say who may do what

Your code acts as the signed-in user, in a *scope*. A scope names who acts, the *principal*, and the
statements that say what they may do. Each statement allows some actions on the resources its
patterns match. A role is a named set of actions.

Here a user owns everything of their own, and may read and message their org's agents:

```elixir title="lib/my_app/agents.ex"
defmodule MyApp.Agents do
  @moduledoc "What users do with agents."

  @doc "The scope `user` acts in: owner of their own agents, reader and messenger on their org's."
  def scope(%MyApp.Accounts.User{} = user) do
    MyApp.Wardrik.as(principal(user), roles: [:owner], resources: ["#{owner(user)}/*"])
    |> Wardrik.grant(roles: [:reader, :messenger], resources: ["#{user.org}/agent/*"])
  end

  @doc "Who `user` is to Wardrik: `acme/@42`, named by their email."
  def principal(user), do: Wardrik.principal(owner(user), %{name: user.email})

  @doc "The namespace `user` owns agents and accounts under, as `acme/@42`."
  def owner(user), do: "#{user.org}/@#{user.id}"
end
```

Maria, user 42 of `acme`, owns the agent `acme/@42/support`, whose resource is
`acme/@42/agent/support`. Her org's own agents, as `acme/triage`, are `acme/agent/triage`, so she
may read and message them. She reaches no other user's agents, and no other org's. Anything she
can't reach answers `not_found`, so she learns nothing about it.

| Role | Allows |
| --- | --- |
| `:reader` | reading an agent, its events, its accounts and servers |
| `:messenger` | asking, cancelling and clearing |
| `:approver` | deciding the calls an agent waits on |
| `:definer` | defining, starting, stopping and forgetting agents; connecting accounts; adding servers |
| `:owner` | every action |

Nothing is allowed unless a statement grants it. [Who may do what](https://hexdocs.pm/wardrik/access.html)
covers actions, patterns and writing your own `Wardrik.Authorizer`.

## 5. Define an agent and ask it

Define Maria's support agent, and ask it something:

```elixir
maria = %MyApp.Accounts.User{id: 42, org: "acme", email: "maria@acme.example"}
scope = MyApp.Agents.scope(maria)

{:ok, agent} =
  Wardrik.Agent.define(scope, "acme/@42/support",
    model: "anthropic:claude-sonnet-5",
    instructions: "Answer questions about orders in two sentences."
  )

{:ok, %Wardrik.Reply{text: text}} = Wardrik.Agent.reply(scope, agent, "Where is order 1001?")
```

The model's key is `ANTHROPIC_API_KEY` in your environment. Every call through a scope checks its
statements, and what it changes is recorded in the audit.

`reply/4` waits for the run to end. It returns one of:

- `{:ok, %Wardrik.Reply{}}`: the run finished.
- `{:waiting, interrupts}`: a call waits on a person. See [Approvals](/concepts/approvals/).
- `{:error, %Wardrik.Error{}}`: the agent can't be reached, or the run failed.

To show a turn as it streams, say in a LiveView, send the answer to the process:

```elixir title="lib/my_app_web/live/support_live.ex"
def handle_event("ask", %{"text" => text}, socket) do
  scope = MyApp.Agents.scope(socket.assigns.current_user)
  {:ok, _ref} = Wardrik.Agent.stream(scope, "acme/@42/support", text, to: self())
  {:noreply, assign(socket, answer: "")}
end

def handle_info({Wardrik, _ref, {:text, chunk}}, socket),
  do: {:noreply, update(socket, :answer, &(&1 <> chunk))}

def handle_info({Wardrik, _ref, _ended}, socket), do: {:noreply, socket}
```

Each message is `{Wardrik, ref, item}`. The items are `{:text, chunk}`, then one of
`{:done, %Wardrik.Reply{}}`, `{:waiting, interrupts}` or `{:failed, reason}`. Without `to:`,
`stream/4` returns the text as an `Enumerable`.

## 6. Follow what it does

Every agent writes its events to a log: each model call, tool call and run. Read it from a cursor:

```elixir
{:ok, message} = Wardrik.Agent.ask(scope, "acme/@42/support", "Where is order 1001?")
{:ok, %Wardrik.Page{events: events, next: next}} =
  Wardrik.Agent.events(scope, "acme/@42/support", after: message.cursor)

Enum.find(events, &(&1.type == "wardrik.run.completed"))
```

Notice `message.cursor`. It's where the log stood as the message was sent, so the turn that answers
it comes after. Read on from `next`.

To follow many agents as they write, stream them:

```elixir
{:ok, stream} =
  Wardrik.Events.stream_list(scope, resources: ["acme/@42/*"], types: ["wardrik.run.completed"])

Enum.each(stream, fn {%Wardrik.Event{} = event, cursor} -> MyApp.Runs.record(event, cursor) end)
```

It reads what's there, then follows new events. Wardrik keeps no reader's place, so keep the cursor
with your work. [Follow events into your app](/build/listen/) does that for you, in your own
tables, with a `Wardrik.Listener`. [Events](/concepts/events/) lists the types.

## Hold each org to its plan

Each org's agents can spend from one allowance together, the one its plan pays for. Give Wardrik
your orgs:

```elixir title="lib/my_app/orgs.ex"
defmodule MyApp.Orgs do
  @moduledoc "Each org's settings: one ceiling, the allowance its plan pays for."

  @behaviour Wardrik.Orgs

  @impl true
  def settings(org, _config) do
    usd = MyApp.Billing.allowance_usd(org)
    {:ok, %Wardrik.OrgSettings{ceilings: %{"plan" => [usd: usd, per: :month]}}}
  end
end
```

```elixir title="config/config.exs"
config :my_app, MyApp.Wardrik,
  store: {WardrikStore.Ecto, repo: MyApp.Repo},
  orgs: {MyApp.Orgs, []}
```

Every agent of `acme`, its users' too, spends from `acme`'s `plan`. Once it's spent, the next model
call waits for someone allowed `ceiling.approve` on `acme/ceiling`, such as an owner of
`acme/*`, to approve more. `on_exhausted: :deny` refuses it instead.

Wardrik reads an org's settings as each of its agents starts, wakes or is defined. When a plan
changes, bring the org's awake agents to it at once:

```elixir
Wardrik.refresh(MyApp.Wardrik, org: "acme")
#=> []
```

`Wardrik.OrgSettings` also takes a policy every agent in the org is held to, policies its
definitions may name, and defaults. See [Budgets](/concepts/budgets/).

## Serve the HTTP API

To let other programs reach the agents, such as the TypeScript SDK, serve the API from your router.
It knows each request by an authenticator of yours. This one reads a token your app gives its user,
signed with your endpoint's secret:

```elixir title="lib/my_app_web/agents_auth.ex"
defmodule MyAppWeb.AgentsAuth do
  @moduledoc "Knows a request to the agents' API by a token this app gave its user."

  @behaviour WardrikHTTP.Authenticator

  @day 86_400

  @doc "A token `user` presents as `Authorization: Bearer TOKEN`."
  def token(user), do: Phoenix.Token.sign(MyAppWeb.Endpoint, "agents", user.id)

  @impl true
  def authenticate(conn, _server, _config) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, id} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "agents", token, max_age: @day) do
      {:ok, MyApp.Agents.scope(MyApp.Accounts.get_user!(id))}
    else
      _not_signed_in -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
    end
  end
end
```

Forward a path to it:

```elixir title="lib/my_app_web/router.ex"
forward "/agents", Wardrik.HTTP,
  wardrik: MyApp.Wardrik,
  authenticator: {MyAppWeb.AgentsAuth, []}
```

Your endpoint parses bodies before the router. Have it keep the raw body too, so Wardrik can check
the signatures of webhooks and chat apps:

```elixir title="lib/my_app_web/endpoint.ex"
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Phoenix.json_library(),
  body_reader: Wardrik.HTTP.body_reader()
```

Now Maria's programs list her agents with the token your app gave her:

```sh
curl -H "Authorization: Bearer $TOKEN" https://myapp.example.com/agents/v1/agents
```

A request acts in the scope your authenticator returns, so it reaches what Maria reaches. The API
also offers your agents the tools of programs that connect to it as
[tool workers](/build/tool-workers/), which a definition names as `workers/*`.

To serve it on a port of its own instead, start it as a child after `MyApp.Wardrik`:
`{Wardrik.HTTP, wardrik: MyApp.Wardrik, port: 4850}`. The [HTTP API guide](/build/http-api/) walks
through the routes.

## Let people connect accounts

An agent can call GitHub's MCP server as the user it works for. Each user connects their own GitHub
account once, and their agents use it from then on.

### Give it a key and a GitHub app

Accounts are kept in the store, sealed with a key you hold. Make one:

```sh
mix run -e 'IO.puts(WardrikVault.generate_key())'
```

Keep it as `WARDRIK_KEY` wherever the app runs. Then:

1. Register an OAuth app on GitHub.
2. Set its callback URL to `https://myapp.example.com/agents/oauth/callback`.
3. Set `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`.

### Give Wardrik the sign-in and the server

```elixir title="config/runtime.exs"
config :my_app, MyApp.Wardrik,
  # 1. Seals accounts and secrets
  keys: [System.fetch_env!("WARDRIK_KEY")],
  # 2. What people sign in to
  oauth: [
    page: "https://myapp.example.com/agents/oauth",
    client_name: "My app",
    providers: [
      github: [
        issuer: "https://github.com/login/oauth",
        client_id: System.fetch_env!("GITHUB_CLIENT_ID"),
        client_secret: System.fetch_env!("GITHUB_CLIENT_SECRET"),
        scopes: ~w(repo)
      ]
    ]
  ],
  # 3. The server, called with each user's own GitHub account
  mcp: [
    github: [
      transport: {:streamable_http, base_url: "https://api.githubcopilot.com/mcp/"},
      credential_name: "github"
    ]
  ]
```

- `page` is where the sign-in pages are served. `Wardrik.HTTP` serves them at `/oauth` under its
  path, so the API's mount gives them `/agents/oauth`.
- `credential_name: "github"` makes each call with the account of the user the agent works for. It
  names the provider that grants it.
- A definition names the server's tools as `github/*`.

### Connect, then use it

Give Maria an agent that uses GitHub, and the link to connect her account:

```elixir
{:ok, _agent} =
  Wardrik.Agent.define(scope, "acme/@42/triage",
    model: "anthropic:claude-sonnet-5",
    instructions: "Sort new issues in acme/shop by how urgent they are.",
    tools: ["github/*"]
  )

{:ok, %Wardrik.Connecting{connected: false, authorization: %Wardrik.Authorization{url: url}}} =
  Wardrik.Connections.connect(scope, "github", owner: "acme/@42")
```

Show her `url`. She signs in at GitHub, and comes back to `/agents/oauth/callback`. Her connections
then say she holds it:

```elixir
{:ok, [%Wardrik.Connection{provider: "github", connected: true}]} =
  Wardrik.Connections.list(scope, owner: "acme/@42")
```

If her agent calls GitHub before she connects, the call waits on an `:authorization` interrupt.
`Wardrik.Agent.authorization/4` gives its link, and the call carries on once she signs in. GitHub's
tools that change something wait for a person to approve them; see [Approvals](/concepts/approvals/).

To serve the callback from a controller of your own, pass its params to
`Wardrik.finish_sign_in(MyApp.Wardrik, params)`. [Connect accounts](/build/accounts/) covers whose
account a call uses.

## Answer in Slack

Your users already talk in Slack, and they won't edit agent files. Let's have each org's agents
answer in that org's own Slack workspace, through one Slack app of yours. Add the package:

```elixir title="mix.exs"
{:wardrik_slack, "~> 0.1.0-rc.1"}
```

### Make the Slack app

1. Make the app from the [manifest](/channels/slack/#a-slack-app).
2. Put `https://myapp.example.com/agents` in place of the manifest's address, so Slack sends its
   events to `/agents/v1/channels/slack/events` and its button presses to
   `/agents/v1/channels/slack/actions`.
3. Under **OAuth & Permissions**, set the **Redirect URL** to `https://myapp.example.com/slack/installed`.
4. Under **Manage Distribution**, let other workspaces install it.
5. Set `SLACK_CLIENT_ID`, `SLACK_CLIENT_SECRET` and `SLACK_SIGNING_SECRET` from **Basic
   Information › App Credentials**.

### Give Wardrik the channel

```elixir title="config/runtime.exs"
config :my_app, MyApp.Wardrik,
  channels: [
    slack:
      {WardrikSlack,
       client_id: System.fetch_env!("SLACK_CLIENT_ID"),
       client_secret: System.fetch_env!("SLACK_CLIENT_SECRET"),
       signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
       redirect_uri: "https://myapp.example.com/slack/installed",
       installations: :stored,
       offering: "An admin of your org can turn on Slack in the agent's settings.",
       deciding: "Your org's admins name who approves in its Slack settings."}
  ]
```

- `installations: :stored` keeps each workspace in Wardrik's store, with its bot token sealed by
  your `:keys`.
- `offering` is what a room with no agent is told. `deciding` is what someone who may not approve is
  told.

Someone in a workspace acts as a principal like `slack:T0123/U024BE7LH`. They may read and message
the agents of the org that added the workspace. Whoever asked for a turn may decide what it waits
on.

### Add it to a workspace

An org's admin adds the app from your settings, signed in:

```elixir title="lib/my_app_web/router.ex"
scope "/slack", MyAppWeb do
  pipe_through [:browser, :require_org_admin]

  get "/add", SlackController, :add
  get "/installed", SlackController, :installed
end
```

```elixir title="lib/my_app_web/controllers/slack_controller.ex"
defmodule MyAppWeb.SlackController do
  use MyAppWeb, :controller

  def add(conn, _params) do
    {:ok, url} =
      Wardrik.Channels.install_url(MyApp.Wardrik, "slack", org(conn), return_to: "/settings")

    redirect(conn, external: url)
  end

  def installed(conn, _params) do
    case Wardrik.Channels.installed(MyApp.Wardrik, "slack", org(conn), conn.query_params) do
      {:ok, _installation, return_to} -> redirect(conn, to: return_to || "/settings")
      {:error, message} -> conn |> put_status(400) |> text(message)
    end
  end

  # The org the signed-in admin acts for.
  defp org(conn), do: conn.assigns.current_user.org
end
```

Notice `:require_org_admin`. `install_url/4` adds the workspace for whatever org it's given, so only
let an org's admins reach it. The URL lasts ten minutes, and nobody else's URL adds a workspace for
that org.

### Give an agent the channel

The workspace answers for the org's own agents, as `acme/support`. Let an admin define them, with
`"slack"` among its channels:

```elixir
admin = MyApp.Agents.scope(maria) |> Wardrik.grant(roles: [:definer], resources: ["acme/agent/*"])

{:ok, _agent} =
  Wardrik.Agent.define(admin, "acme/support",
    model: "anthropic:claude-sonnet-5",
    instructions: "Answer questions about orders in two sentences.",
    channels: ["slack"]
  )
```

Invite the app into a Slack channel, and mention it. The agent answers in a thread.

Reach for this when your users live in Slack and never touch agent files. Running the daemon for one
team? Give its channel a `token` in `config.yaml` instead; see [Slack](/channels/slack/).

## Details

### Approvers in each workspace

With `installations: :stored`, every new workspace gets the channel's `:approvers`, `[]` unless
set. To let each org name its own, keep workspaces in your own tables: pass
`installations: {MyApp.SlackWorkspaces, []}`, a module implementing
`Wardrik.Channel.Installations`. Each `Wardrik.Channel.Installation` it returns carries its
`approvers`.

### Keeping it elsewhere

`:store` takes:

```elixir
# In memory, gone when it stops: the default, for development and tests
store: {WardrikStore.ETS, []}

# On each node's disk
store: {WardrikStore.EKV, data_dir: "/var/lib/my_app"}

# In a Postgres of its own, which creates its table itself
store: {WardrikStore.Ecto, url: "postgres://user:pass@db.example.com/my_app"}
```

[Storage](/run/storage/) compares them.

### A new release

A release that writes agents differently needs no cleanup. See
[Upgrade and back up](/run/upgrade-and-back-up/#details).

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
