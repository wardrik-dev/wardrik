defmodule WardrikWeb.NodesLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5_000, :tick)
    {:ok, socket |> assign(page_title: "Nodes", nodes: [], asleep: 0, error: nil) |> load()}
  end

  @impl true
  def handle_event("reload", _params, socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "deployment.reload", %{}) do
      {:ok, _answer} ->
        {:noreply, socket |> put_flash(:info, "Read every agent's definition again.") |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "deployment.nodes", %{}) do
      {:ok, %{"nodes" => nodes, "asleep" => asleep}} ->
        assign(socket, nodes: nodes, asleep: asleep, error: nil)

      {:error, error} ->
        assign(socket, error: error.message)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.head title="Nodes" lead="Where agents run. Refreshes every 5 seconds.">
      <:actions>
        <button class="btn" phx-click="reload" data-confirm="Read every agent's definition again?">Reload definitions</button>
      </:actions>
    </.head>
    <div :if={@error} class="flash error">{@error}</div>
    <div class="stats">
      <div class="stat"><b>{length(@nodes)}</b><span>nodes</span></div>
      <div class="stat"><b>{Enum.sum_by(@nodes, & &1["agents"])}</b><span>agents running</span></div>
      <div class="stat"><b>{@asleep}</b><span>agents asleep</span></div>
    </div>
    <div class="card">
      <table class="list">
        <thead>
          <tr>
            <th>Node</th><th class="num">Agents</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={node <- @nodes}>
            <td class="mono">{node["name"]}</td><td class="num">{node["agents"]}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
