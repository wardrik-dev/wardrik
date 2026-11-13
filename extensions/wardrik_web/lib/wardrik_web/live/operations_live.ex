defmodule WardrikWeb.OperationsLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.Operations

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "Operations", query: "")}

  @impl true
  def handle_event("filter", %{"query" => query}, socket),
    do: {:noreply, assign(socket, :query, query)}

  defp groups(operations) do
    operations
    |> Enum.sort_by(& &1.id)
    |> Enum.group_by(& &1.subject)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp matching(query) do
    query =
      query
      |> String.trim()
      |> String.downcase()

    Enum.filter(WardrikProtocol.operations(), fn operation ->
      query == "" or
        String.contains?(String.downcase(operation.id <> " " <> operation.summary), query)
    end)
  end

  @impl true
  def render(assigns) do
    {inbound, people} =
      assigns.query
      |> matching()
      |> Enum.split_with(&Operations.inbound?/1)

    assigns = assign(assigns, people: groups(people), inbound: groups(inbound))

    ~H"""
    <.head
      title="Operations"
      lead="Run any operation from a form. Operations you can't access return an error."
    />

    <form id="operations-filter" class="filters" phx-change="filter" phx-submit="filter">
      <input
        type="search"
        name="query"
        value={@query}
        placeholder="Find an operation"
        aria-label="Find an operation"
        phx-debounce="100"
      />
    </form>

    <.group
      :for={{subject, operations} <- @people}
      subject={subject}
      operations={operations}
      dashboard={@dashboard}
    />
    <div :if={@people == [] and @inbound == []} class="card empty">No operation matches.</div>

    <details :if={@inbound != []} class="inbound" open={@query != ""}>
      <summary>
        <b>Called by webhooks and chat apps</b>
        <span class="sub">Running one here sends a request as if it came from that service.</span>
      </summary>
      <.group
        :for={{subject, operations} <- @inbound}
        subject={subject}
        operations={operations}
        dashboard={@dashboard}
      />
    </details>
    """
  end

  attr :subject, :string, required: true
  attr :operations, :list, required: true
  attr :dashboard, :any, required: true

  defp group(assigns) do
    ~H"""
    <section>
      <h2 class="group-title">{@subject}</h2>
      <div class="ops">
        <.link
          :for={operation <- @operations}
          class="op"
          navigate={WardrikWeb.path(@dashboard, ["operations", operation.id])}
        >
          <div class="id">
            {operation.id}<span class={["tag", operation.effect]}>{operation.effect}</span>
          </div>
          <div class="sum">{operation.summary}</div>
        </.link>
      </div>
    </section>
    """
  end
end
