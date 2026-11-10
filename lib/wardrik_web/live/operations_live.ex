defmodule WardrikWeb.OperationsLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  @impl true
  def mount(_params, _session, socket) do
    groups =
      WardrikProtocol.operations()
      |> Enum.sort_by(& &1.id)
      |> Enum.group_by(& &1.subject)
      |> Enum.sort_by(&elem(&1, 0))

    {:ok, assign(socket, page_title: "Operations", groups: groups)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.head
      title="Operations"
      lead="Every operation Wardrik serves, each with a form. Your access decides which run."
    />
    <section :for={{subject, operations} <- @groups}>
      <h2 class="group-title">{subject}</h2>
      <div class="ops">
        <.link
          :for={operation <- operations}
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
