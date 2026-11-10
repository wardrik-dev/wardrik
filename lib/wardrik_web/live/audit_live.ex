defmodule WardrikWeb.AuditLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  @page 100

  @impl true
  def mount(_params, _session, socket),
    do:
      {:ok,
       socket
       |> assign(page_title: "Audit", events: [], next: nil, done: false, error: nil)
       |> more()}

  @impl true
  def handle_event("more", _params, socket), do: {:noreply, more(socket)}

  defp more(socket) do
    input =
      if socket.assigns.next,
        do: %{"limit" => @page, "starting_after" => socket.assigns.next},
        else: %{"limit" => @page}

    case Wardrik.Scope.run(socket.assigns.scope, "audit.list", input) do
      {:ok, %{"events" => events} = page} ->
        assign(socket,
          events: socket.assigns.events ++ events,
          next: page["next"],
          done: length(events) < @page
        )

      {:error, error} ->
        assign(socket, error: error.message)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.head title="Audit" lead="Changes made across the deployment, oldest first." />
    <div :if={@error} class="flash error">{@error}</div>
    <.events
      events={@events}
      empty="No audit events yet."
      dashboard={@dashboard}
      agent
    />
    <button :if={!@done} class="btn" phx-click="more">Show more</button>
    """
  end
end
