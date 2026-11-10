defmodule WardrikWeb.AgentsLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.Follow

  @statuses ~w(running parked idle asleep)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Agents", query: "", only: "", agents: [], error: nil)
      |> load()
      |> Follow.agents()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply, assign(socket, query: params["query"] || "", only: params["only"] || "")}
  end

  @impl true
  def handle_info({Follow, _message} = message, socket),
    do: {:noreply, Follow.handle(message, socket, &load/1)}

  defp load(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "agents.list", %{}) do
      {:ok, %{"agents" => agents}} -> assign(socket, agents: agents, error: nil)
      {:error, error} -> assign(socket, error: error.message)
    end
  end

  defp shown(agents, query, only) do
    query = String.downcase(query)

    Enum.filter(agents, fn agent ->
      (only == "" or agent["status"] == only) and
        (query == "" or String.contains?(String.downcase(label(agent)), query))
    end)
  end

  defp label(%{"id" => id, "conversation" => conversation}), do: "#{id} · #{conversation}"
  defp label(%{"id" => id}), do: id

  defp count(agents, status), do: Enum.count(agents, &(&1["status"] == status))

  defp link_to(dashboard, agent),
    do:
      WardrikWeb.path(dashboard, ["agents", agent["id"]], %{
        "conversation" => agent["conversation"]
      })

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        statuses: @statuses,
        shown: shown(assigns.agents, assigns.query, assigns.only)
      )

    ~H"""
    <.head title="Agents" lead="Every agent and conversation you may see.">
      <:actions>
        <.live live={@live} stopped={@stopped} />
        <.link class="btn primary" navigate={WardrikWeb.path(@dashboard, ["new"])}>New agent</.link>
      </:actions>
    </.head>

    <div :if={@error} class="flash error">{@error}</div>

    <div class="stats">
      <div class="stat"><b>{length(@agents)}</b><span>agents and conversations</span></div>
      <div :for={status <- @statuses} class="stat">
        <b>{count(@agents, status)}</b><span>{status}</span>
      </div>
    </div>

    <.panels dashboard={@dashboard} slot={:agents} scope={@scope} assigns={%{agents: @agents}} />

    <form id="agents-filter" class="filters" phx-change="filter" phx-submit="filter">
      <input
        type="search"
        name="query"
        value={@query}
        placeholder="Find an agent"
        aria-label="Find an agent"
        phx-debounce="150"
      />
      <select name="only" aria-label="Status">
        <option value="">Any status</option>
        <option :for={status <- @statuses} value={status} selected={status == @only}>{status}</option>
      </select>
    </form>

    <div class="card">
      <table class="list stack">
        <thead>
          <tr>
            <th>Agent</th>
            <th>Status</th>
            <th class="num">Waiting</th>
            <th class="num">Spent today</th>
            <th class="wide">Next run</th>
            <th class="wide">Node</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={agent <- @shown}>
            <td class="lead">
              <.link navigate={link_to(@dashboard, agent)}>{agent["id"]}</.link>
              <div :if={agent["conversation"]} class="sub">{agent["conversation"]}</div>
            </td>
            <td data-label="Status"><.status value={agent["status"]} /></td>
            <td class="num" data-label="Waiting">{agent["pending"]}</td>
            <td class="num" data-label="Spent today">{usd(agent["spent_today"]["usd"])}</td>
            <td class="wide sub" data-label="Next run">{ago(agent["next_run"])}</td>
            <td class="wide sub mono" data-label="Node">{agent["node"] || "—"}</td>
          </tr>
        </tbody>
      </table>
      <div :if={@shown == []} class="empty">
        {if @agents == [], do: "No agents yet.", else: "No agent matches."}
      </div>
    </div>
    """
  end
end
