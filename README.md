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
| Agent | One agent's timeline, runs, running tool calls, triggers, definition and events. |
| Approvals | Tool calls that are waiting for approval. |
| Audit | The audit log. |
| Nodes | The nodes in the cluster. |
| Operations | A form for each operation. |

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

## Add pages and panels

Extensions add pages and panels to the dashboard. See `WardrikWeb.Extension`.

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
