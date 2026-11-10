# WardrikWeb

A dashboard for [Wardrik](https://hexdocs.pm/wardrik)'s operators, mounted in your Phoenix router.

* **Agents**: every agent and conversation, live.
* **Agent**: its timeline as it runs, with approvals inline, plus runs, running calls,
  definition and events.
* **Approvals**: every call waiting on a person.
* **Audit**, **Nodes**, and **Operations**: a form for every operation of
  [WardrikProtocol](https://hexdocs.pm/wardrik_protocol).

Each page runs operations in the scope your resolver gives, so Wardrik's authorizer decides what
each person sees and does.

## Install

```elixir
def deps do
  [
    {:wardrik_web, "~> 0.1.0-rc.1"}
  ]
end
```

## Mount it

```elixir
import WardrikWeb.Router

scope "/admin" do
  pipe_through [:browser, :require_admin]

  wardrik_dashboard "/wardrik",
    resolver: {MyAppWeb.WardrikResolver, []},
    on_mount: [{MyAppWeb.UserAuth, :require_admin}]
end
```

* The pipeline must fetch the session and protect from forgery, as Phoenix's `:browser` does.
* The endpoint must serve LiveView's socket with the session, as `mix phx.new` sets it up.
* `on_mount` runs your hooks first, so the resolver can read what they assign.
* Assets are built in. There's nothing to add to `app.js` or `app.css`.

## Resolve who's signed in

```elixir
defmodule MyAppWeb.WardrikResolver do
  @behaviour WardrikWeb.Resolver

  @impl true
  def scope(%WardrikWeb.Resolver.Request{assigns: %{current_user: %{admin: true} = user}}, _opts),
    do: {:ok, MyApp.AgentRuntime.as(user.id)}

  def scope(_request, _opts), do: {:error, Wardrik.Error.new(:unauthorized, "Admins only.")}
end
```

It runs on every mount, so a person who loses access loses the dashboard on their next reconnect.

## Extend it

An extension adds pages and panels. See `WardrikWeb.Extension`.

```elixir
wardrik_dashboard "/wardrik", resolver: {MyAppWeb.WardrikResolver, []}, extensions: [MyExtension]
```

## Related

* [Wardrik](https://hexdocs.pm/wardrik)
* [WardrikProtocol](https://hexdocs.pm/wardrik_protocol)
* [WardrikHTTP](https://hexdocs.pm/wardrik_http)
