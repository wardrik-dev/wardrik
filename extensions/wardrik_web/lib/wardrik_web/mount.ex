defmodule WardrikWeb.Mount do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, redirect: 2]

  alias WardrikWeb.Dashboard
  alias WardrikWeb.Resolver.Request

  @doc "Assigns the scope the resolver returns, or redirects to the sign-in page."
  def on_mount(%Dashboard{resolver: {resolver, opts}} = dashboard, _params, session, socket) do
    request = %Request{session: session, endpoint: socket.endpoint, assigns: socket.assigns}

    case resolver.scope(request, opts) do
      {:ok, scope} ->
        socket =
          socket
          |> assign(:scope, scope)
          |> assign(:dashboard, dashboard)
          |> assign(:here, dashboard.prefix)
          |> attach_hook(:here, :handle_params, &here/3)

        {:cont, socket}

      {:error, _why} ->
        {:halt, redirect(socket, to: dashboard.sign_in)}
    end
  end

  defp here(_params, uri, socket), do: {:cont, assign(socket, :here, URI.parse(uri).path)}
end
