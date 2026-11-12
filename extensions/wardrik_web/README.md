# WardrikWeb

WardrikWeb is a web dashboard for [Wardrik](https://hexdocs.pm/wardrik) agents. You add it to
your Phoenix app.

With the dashboard you can:

* See all your agents and what they are doing.
* Approve or reject tool calls.
* Edit an agent's definition and triggers.
* Run any [WardrikProtocol](https://hexdocs.pm/wardrik_protocol) operation from a form.

## Pages

| Page | What it shows |
| --- | --- |
| Agents | All agents and conversations you can access. |
| Agent | One agent's timeline, runs, running tool calls, triggers, definition, access and events. |
| Approvals | Tool calls that are waiting for approval. |
| Audit | The audit log. |
| Nodes | The nodes in the cluster and their resource use. |
| Operations | A form for each operation. |
| Settings | MCP servers, secrets, notify targets, OAuth apps and connections. Off until you turn them on. |

The pages update while agents run.

## Install

Add `wardrik_web` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:wardrik_web, "~> 0.1.0-rc.1"}
  ]
end
```

## Add the dashboard to your router

You need:

* A Phoenix app with LiveView. An app created with `mix phx.new` works.
* A running Wardrik instance, for example `MyApp.AgentRuntime`.

Add the dashboard to your router:

```elixir
import WardrikWeb.Router

scope "/admin" do
  pipe_through [:browser, :require_admin]

  wardrik_dashboard "/wardrik",
    resolver: {MyAppWeb.WardrikResolver, []},
    on_mount: [{MyAppWeb.UserAuth, :require_admin}]
end
```

Open `/admin/wardrik` in your browser to see the dashboard.

Notes:

* Use a pipeline that fetches the session and checks CSRF tokens. Phoenix's `:browser` pipeline
  does both.
* Your `:on_mount` hooks run before the resolver. The resolver can read the assigns they set.
* The dashboard serves its own JavaScript and CSS. You don't need to change `app.js` or
  `app.css`.

## Write a resolver

The resolver decides who can use the dashboard. It returns the scope each person acts in.

```elixir
defmodule MyAppWeb.WardrikResolver do
  @behaviour WardrikWeb.Resolver

  @impl true
  def scope(%WardrikWeb.Resolver.Request{assigns: %{current_user: %{admin: true} = user}}, _opts),
    do: {:ok, MyApp.AgentRuntime.as(user.id)}

  def scope(_request, _opts), do: {:error, Wardrik.Error.new(:unauthorized, "Admins only.")}
end
```

The dashboard runs every action in this scope. Wardrik's authorizer checks each action.

The dashboard calls the resolver each time a page loads. When you remove someone's access, they
lose the dashboard the next time their browser reconnects.

## Turn on the settings pages

Your app keeps its agents' MCP servers, secrets, notify targets and OAuth apps. The settings
pages list, add and remove them through a module you write. Each page you don't turn on shows
in the navigation, with a note on how to turn it on.

```elixir
wardrik_dashboard "/wardrik",
  resolver: {MyAppWeb.WardrikResolver, []},
  settings: [
    servers: {MyApp.WardrikServers, []},
    secrets: {MyApp.WardrikSecrets, []},
    connections: {MyApp.WardrikConnections, []}
  ]
```

`:servers`, `:secrets`, `:notify_targets` and `:oauth_apps` take a `WardrikWeb.Settings`.
`:connections` takes a `WardrikWeb.Connections`.

## Add pages and panels

Extensions add pages and panels to the dashboard. See `WardrikWeb.Extension`. Write a page
with `use WardrikWeb.Page`.

```elixir
wardrik_dashboard "/wardrik",
  resolver: {MyAppWeb.WardrikResolver, []},
  extensions: [MyAppWeb.DashboardExtension]
```

## Related

* [Wardrik](https://hexdocs.pm/wardrik)
* [WardrikProtocol](https://hexdocs.pm/wardrik_protocol)
* [WardrikWebPro](https://github.com/wardrik-dev/wardrik_web_pro) adds fleet pages and bulk
  actions.
* The [Wardrik daemon](https://wardrik.dev) serves this dashboard at `/web`.
