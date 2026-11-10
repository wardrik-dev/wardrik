defmodule WardrikWeb.ApprovalsLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.Follow

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Approvals", interrupts: [], error: nil)
      |> load()
      |> Follow.agents()

    {:ok, socket}
  end

  @impl true
  def handle_event("approve", %{"agent" => agent, "interrupt" => id} = params, socket) do
    input =
      %{"agent" => agent, "interrupt" => id}
      |> present("note", params["note"])
      |> present("conversation", params["conversation"])

    {:noreply, decide(socket, "agent.approve", input, "Approved.")}
  end

  def handle_event("deny", %{"agent" => agent, "interrupt" => id} = params, socket) do
    input =
      %{"agent" => agent, "interrupt" => id} |> present("conversation", params["conversation"])

    {:noreply, decide(socket, "agent.deny", input, "Rejected.")}
  end

  @impl true
  def handle_info({Follow, _message} = message, socket),
    do: {:noreply, Follow.handle(message, socket, &load/1)}

  defp decide(socket, id, input, done) do
    case Wardrik.Scope.run(socket.assigns.scope, id, input) do
      {:ok, _answer} -> socket |> put_flash(:info, done) |> load()
      {:error, error} -> put_flash(socket, :error, error.message)
    end
  end

  defp present(map, _key, value) when value in [nil, ""], do: map
  defp present(map, key, value), do: Map.put(map, key, value)

  defp load(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "interrupts.list", %{}) do
      {:ok, %{"interrupts" => interrupts}} -> assign(socket, interrupts: interrupts, error: nil)
      {:error, error} -> assign(socket, error: error.message)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.head title="Approvals" lead="Tool calls waiting for approval.">
      <:actions><.live live={@live} stopped={@stopped} /></:actions>
    </.head>
    <div :if={@error} class="flash error">{@error}</div>
    <div :if={@interrupts == []} class="card empty">No pending approvals.</div>
    <div :for={%{"agent" => agent, "interrupt" => interrupt} = waiting <- @interrupts} class="card">
      <header>
        <span>
          <.link navigate={
            WardrikWeb.path(@dashboard, ["agents", agent["id"]], %{
              "conversation" => waiting["conversation"]
            })
          }>{agent["id"]}</.link>
          <span :if={waiting["conversation"]} class="sub"> · {waiting["conversation"]}</span>
        </span>
        <span class="pill waiting">waiting</span>
      </header>
      <div class="body">
        <div style="font-weight: 600; margin-bottom: 4px">
          {interrupt["message"] || "Approve #{interrupt["name"]}?"}
        </div>
        <div class="sub">
          <code>{interrupt["name"]}</code> · {interrupt["reason"]}
          <span :for={label <- interrupt["labels"] || []} class="tag">{label}</span>
        </div>
        <details :if={interrupt["arguments"]} style="margin-top: 8px" open>
          <summary>Arguments</summary>
          <.json value={interrupt["arguments"]} />
        </details>
        <form phx-submit="approve" class="filters" style="margin: 12px 0 0">
          <input type="hidden" name="agent" value={agent["id"]} />
          <input type="hidden" name="conversation" value={waiting["conversation"]} />
          <input type="hidden" name="interrupt" value={interrupt["id"]} />
          <input type="text" name="note" placeholder="Note (optional)" aria-label="Note" />
          <button class="btn primary">Approve</button>
          <button
            class="btn danger"
            type="button"
            phx-click="deny"
            phx-value-agent={agent["id"]}
            phx-value-conversation={waiting["conversation"]}
            phx-value-interrupt={interrupt["id"]}
          >
            Reject
          </button>
        </form>
      </div>
    </div>
    """
  end
end
