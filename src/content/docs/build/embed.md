---
title: Embed in your app
description: "Run Wardrik inside your Elixir app: in your supervision tree, kept in your Postgres, asking your app who may do what."
sidebar:
  order: 4.5
---

Wardrik has no users of its own. It asks your app two things:

- **May this user do this?** Your authorizer answers yes or no.
- **What does this agent get?** Your resolver says who it works for, and what it may reach.

## 1. Add the package

```elixir title="mix.exs"
{:wardrik, "~> 0.1.0-rc.2"}
```

Create Wardrik's table in your Postgres:

```elixir title="priv/repo/migrations/20261102000000_add_wardrik.exs"
defmodule MyApp.Repo.Migrations.AddWardrik do
  use Ecto.Migration

  def up, do: WardrikStore.Ecto.Migration.up(version: 1)
  def down, do: WardrikStore.Ecto.Migration.down(version: 1)
end
```

## 2. Say who may do what

```elixir title="lib/my_app/agent_authorizer.ex"
defmodule MyApp.AgentAuthorizer do
  @behaviour Wardrik.Authorizer

  @impl true
  def authorize(%{principal: %{id: user}, resource: {:agent, id}}, _opts) do
    case MyApp.Agents.get(id) do
      %{user_id: ^user} -> :ok
      _other -> {:error, :not_found}
    end
  end

  def authorize(_request, _opts), do: {:error, :forbidden}
end
```

- Wardrik calls it before every operation, with a `Wardrik.Authorizer.Request`.
- `request.action` is the operation, as `"agent.ask"`.
- `{:error, :not_found}` tells the caller nothing about what they can't see.
- `MyApp.Agents` is your own table of agents. Wardrik keeps none.

## 3. Say what each agent gets

```elixir title="lib/my_app/agent_resolver.ex"
defmodule MyApp.AgentResolver do
  @behaviour Wardrik.Resolver

  @impl true
  def resolve(%Wardrik.Resolver.Request{agent: id}, _opts) do
    case MyApp.Agents.get(id) do
      nil -> {:error, Wardrik.Error.new(:not_found, "There's no agent #{id} here.")}
      agent -> {:ok, %Wardrik.Resolved{principal: Wardrik.principal(agent.user_id)}}
    end
  end
end
```

- `principal` is who the agent works for. Its keys and credentials are that user's.
- `Wardrik.Resolved` also takes a `policy`, `defaults`, MCP `servers`, `notify` targets, chat
  `channels` and shared `workspaces`. An agent reaches nothing you don't list.
- Wardrik resolves an agent as it's defined, starts and wakes. `Wardrik.refresh/2` applies a change
  to agents already awake.

## 4. Start it

```elixir title="lib/my_app/agent_runtime.ex"
defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app
end
```

```elixir title="config/config.exs"
config :my_app, MyApp.AgentRuntime,
  store: {WardrikStore.Ecto, repo: MyApp.Repo},
  authorizer: {MyApp.AgentAuthorizer, []},
  resolver: {MyApp.AgentResolver, []}
```

```elixir title="lib/my_app/application.ex"
children = [
  MyApp.Repo,
  MyApp.AgentRuntime,
  MyAppWeb.Endpoint
]

Supervisor.start_link(children, strategy: :rest_for_one, name: MyApp.Supervisor)
```

`Wardrik.start_link/1` lists every option. `:rest_for_one` restarts your endpoint with Wardrik.

## 5. Define an agent and ask it

```elixir
%{id: id} = MyApp.Agents.create!(user_id: "user_42", name: "support")
scope = MyApp.AgentRuntime.as("user_42")

{:ok, _agent} =
  Wardrik.Agent.define(scope, id,
    model: "anthropic:claude-sonnet-5",
    instructions: "Answer questions about orders in two sentences."
  )

{:ok, %Wardrik.Reply{text: text}} = Wardrik.Agent.reply(scope, id, "Where is order 1001?")
```

- Insert your row first: Wardrik resolves the agent as it's defined.
- An agent ID is any string your app picks.
- `reply/4` returns `{:ok, reply}`, `{:waiting, interrupts}` when a call waits on a person, or
  `{:error, error}`.
- The model's key is `ANTHROPIC_API_KEY` in your environment, unless you give a `key_source:`.

Stream a turn into a LiveView:

```elixir
def handle_event("ask", %{"text" => text}, socket) do
  {:ok, _ref} = Wardrik.Agent.stream(socket.assigns.scope, socket.assigns.agent, text, to: self())
  {:noreply, assign(socket, answer: "")}
end

def handle_info({Wardrik, _ref, {:text, chunk}}, socket),
  do: {:noreply, update(socket, :answer, &(&1 <> chunk))}

def handle_info({Wardrik, _ref, _ended}, socket), do: {:noreply, socket}
```

Approve a call it waits on:

```elixir
{:waiting, [interrupt]} = Wardrik.Agent.reply(scope, id, "Refund order 1001.")
{:ok, _} = Wardrik.Agent.approve(scope, interrupt: interrupt)
```

Read its events from a cursor:

```elixir
{:ok, message} = Wardrik.Agent.ask(scope, id, "Where is order 1001?")
{:ok, page} = Wardrik.Agent.events(scope, id, after: message.cursor)
```

To keep events in your tables, see [Follow events into your app](/build/listen/).

## Model keys

ReqLLM reads keys from its config and the environment. To give each user their own, pass a
`key_source:`:

```elixir
defmodule MyApp.ModelKeys do
  @behaviour WardrikCore.Keys

  @impl true
  def fetch(%WardrikCore.Keys.Request{name: name, principal: principal}, _opts) do
    case MyApp.Billing.api_key(principal.id, name) do
      nil -> {:error, :not_found}
      key -> {:ok, key}
    end
  end
end
```

```elixir
key_source: {MyApp.ModelKeys, []}
```

- `name` is the key's name, as `"ANTHROPIC_API_KEY"`. `Wardrik.key_name/1` gives it for a model.
- `{:error, :not_found}` falls back to ReqLLM.

## Tool credentials

A tool that acts as a person, such as an MCP server called with their GitHub token, fetches a
credential by name. Give your own tokens with `credentials:`:

```elixir
defmodule MyApp.ToolCredentials do
  @behaviour WardrikCore.Credentials

  @impl true
  def resolve(%{name: name, principal: %{id: user}}, _opts) do
    case MyApp.Tokens.get(user, name) do
      nil -> {:authorize, "https://myapp.example.com/connect/#{name}"}
      token -> {:ok, token}
    end
  end
end
```

```elixir
credentials: {MyApp.ToolCredentials, []}
```

`{:authorize, url}` parks the call. `Wardrik.Agent.authorization/2` gives the link to show.

## Let people sign in with OAuth

Without `credentials:`, Wardrik keeps sign-ins in its vault. Give it vault keys, a sign-in page,
and the OAuth app each user signs in with:

```elixir
defmodule MyApp.OAuthApps do
  @behaviour WardrikOAuth.Resolver

  @impl true
  def provider(%{name: "github"}, _opts) do
    {:ok,
     WardrikOAuth.Provider.new("github",
       key: "github",
       issuer: "https://github.com/login/oauth",
       client_id: System.fetch_env!("GITHUB_CLIENT_ID"),
       client_secret: System.fetch_env!("GITHUB_CLIENT_SECRET"),
       scopes: ~w(repo)
     )}
  end

  def provider(_request, _opts), do: {:error, :not_found}
end
```

```elixir title="config/runtime.exs"
config :my_app, MyApp.AgentRuntime,
  vault_keys: [System.fetch_env!("WARDRIK_KEY")],
  oauth: [page: "https://myapp.example.com/agents/oauth", resolver: {MyApp.OAuthApps, []}],
  mcp: [
    github: [
      transport: {:streamable_http, url: "https://api.githubcopilot.com/mcp/"},
      credential_name: "github"
    ]
  ]
```

- Make a key with `mix run -e 'IO.puts(WardrikVault.generate_key())'`.
- `key` names the OAuth app. A grant is refreshed only by the app that issued it.
- Give the server to agents in your resolver: `servers: %{"github" => "github"}`. A definition
  names its tools as `github/*`.
- A call made before the user signs in waits on an `:authorization` interrupt.

Connect an account from your own settings page:

```elixir
user = Wardrik.principal("user_42")

{:ok, %{url: url}} = Wardrik.sign_in(MyApp.AgentRuntime, "github", user)
Wardrik.signing_in?(MyApp.AgentRuntime, "github", user)
#=> true
```

- Send the user to `url`. A device sign-in also gives a `code` to enter there.
- The sign-in comes back to `page`. See [Serve the HTTP API](#serve-the-http-api).
- When you delete an OAuth app, call `Wardrik.forget_client(MyApp.AgentRuntime, key)`.

## Serve the HTTP API

The TypeScript SDK and tool workers reach Wardrik over HTTP. Your authenticator says who each
request is:

```elixir title="lib/my_app_web/agents_auth.ex"
defmodule MyAppWeb.AgentsAuth do
  @behaviour WardrikHTTP.Authenticator

  @impl true
  def authenticate(%{conn: conn, wardrik: wardrik}, _opts) do
    with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, user} <- Phoenix.Token.verify(MyAppWeb.Endpoint, "agents", token, max_age: 86_400) do
      {:ok, Wardrik.as(wardrik, user)}
    else
      _not_signed_in -> {:error, Wardrik.Error.new(:unauthorized, "Sign in first.")}
    end
  end
end
```

```elixir title="lib/my_app_web/router.ex"
forward "/agents", Wardrik.HTTP,
  wardrik: MyApp.AgentRuntime,
  authenticator: {MyAppWeb.AgentsAuth, []},
  principal: {MyAppWeb.Session, :principal, []}
```

- `principal:` says who is at the browser for sign-in callbacks, served at `/agents/oauth`.
- Keep raw bodies for webhook and Slack signatures: `body_reader: Wardrik.HTTP.body_reader()` in
  your `Plug.Parsers`.
- On a port of its own: `{Wardrik.HTTP, wardrik: MyApp.AgentRuntime, authenticator: ..., port: 4850}`.

## Answer in Slack

```elixir title="mix.exs"
{:wardrik_slack, "~> 0.1.0-rc.2"}
```

Each chat member is one of your users. Say which:

```elixir
defmodule MyApp.ChatMembers do
  @behaviour WardrikChannel.Identities

  @impl true
  def identify(%WardrikChannel.Identities.Request{} = request, _opts) do
    case MyApp.Accounts.by_slack(request.workspace, request.member) do
      %{id: id} -> {:ok, Wardrik.principal(id)}
      nil -> {:error, "Link your Slack account in MyApp first."}
    end
  end
end
```

```elixir title="config/runtime.exs"
config :my_app, MyApp.AgentRuntime,
  channels: [
    slack:
      {WardrikSlack,
       client_id: System.fetch_env!("SLACK_CLIENT_ID"),
       client_secret: System.fetch_env!("SLACK_CLIENT_SECRET"),
       signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
       redirect_uri: "https://myapp.example.com/slack/installed",
       installations: :stored,
       identities: {MyApp.ChatMembers, []}}
  ]
```

Add the app to a workspace from your own settings page:

```elixir
{:ok, url} =
  Wardrik.Channels.install_url(MyApp.AgentRuntime,
    channel: "slack",
    owner: "acme",
    return_to: "/settings"
  )

{:ok, _installation, next} =
  Wardrik.Channels.installed(MyApp.AgentRuntime, channel: "slack", owner: "acme", query: params)
```

- Only let the org's admins reach these pages. `owner` is whoever your app says added it.
- A member is offered the agents with `channels: ["slack"]` that your authorizer lets them read.
- Requests from Slack reach your authorizer with `actor: {:channel, "slack"}`.
- Make the Slack app from the [manifest](/channels/slack/#a-slack-app), with
  `https://myapp.example.com/agents` as its address.

## Details

- `store:` also takes `{WardrikStore.ETS, []}` (memory, the default) and
  `{WardrikStore.EKV, data_dir: "/var/lib/my_app"}` (disk). See [Storage](/run/storage/).
- Options come from config, then the child spec, then `init/1` in `MyApp.AgentRuntime`.
- Quiet `DurableServer`'s logs with `Logger.put_application_level(:durable_server, :warning)`.
- With many agents answering at once, raise `config :req_llm, stream_pool_count: 128`.
