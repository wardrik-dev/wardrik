defmodule WardrikWeb.OperationLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.Follow
  alias WardrikWeb.Form

  @kept 100

  @impl true
  def mount(%{"operation" => id}, _session, socket) do
    case WardrikProtocol.operation(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "There's no operation #{id}.")
         |> push_navigate(to: WardrikWeb.path(socket.assigns.dashboard, ["operations"]))}

      operation ->
        {:ok,
         assign(socket,
           page_title: id,
           operation: operation,
           params: %{},
           result: nil,
           error: nil,
           events: [],
           live: nil,
           stopped: nil
         )}
    end
  end

  @impl true
  def handle_event("change", params, socket),
    do: {:noreply, assign(socket, :params, params["input"] || %{})}

  def handle_event("run", params, socket) do
    socket = assign(socket, params: params["input"] || %{}, error: nil)

    with {:ok, input} <- input(socket),
         {:ok, result} <-
           Wardrik.Scope.run(socket.assigns.scope, socket.assigns.operation.id, input) do
      {:noreply, assign(socket, result: result)}
    else
      {:error, %{message: message}} -> {:noreply, assign(socket, result: nil, error: message)}
      {:error, message} -> {:noreply, assign(socket, result: nil, error: message)}
    end
  end

  def handle_event("follow", params, socket) do
    socket = assign(socket, params: params["input"] || %{})

    case input(socket) do
      {:ok, input} ->
        {:noreply,
         socket
         |> assign(events: [], error: nil)
         |> Follow.start(socket.assigns.operation.id, input)}

      {:error, message} ->
        {:noreply, assign(socket, error: message)}
    end
  end

  def handle_event(event, value, socket),
    do: {:noreply, assign(socket, :params, Form.handle(event, value, socket.assigns.params))}

  defp input(socket) do
    case Form.read(socket.assigns.operation.input, socket.assigns.params) do
      :none -> {:ok, %{}}
      read -> read
    end
  end

  @impl true
  def handle_info({Follow, _message} = message, socket),
    do: {:noreply, Follow.handle(message, socket, & &1, on_event: &kept/2)}

  defp kept(event, socket), do: update(socket, :events, &Enum.take([event | &1], @kept))

  @impl true
  def render(assigns) do
    ~H"""
    <.head title={@operation.id} lead={@operation.summary}>
      <:crumb>
        <.link navigate={WardrikWeb.path(@dashboard, ["operations"])}>Operations</.link> /
      </:crumb>
      <:actions>
        <span class={["tag", @operation.effect]}>{@operation.effect}</span>
        <code class="sub">{String.upcase(@operation.method)} {@operation.path}</code>
      </:actions>
    </.head>

    <div :if={WardrikWeb.Operations.inbound?(@operation)} class="flash info" role="note">
      Webhooks and chat apps call this operation. Running it here sends a request as if it came from
      that service.
    </div>

    <div class="layout">
      <div>
        <div class="card">
          <header>Input</header>
          <form
            id="operation-form"
            class="body"
            phx-change="change"
            phx-submit={if @operation.stream, do: "follow", else: "run"}
          >
            <div
              :if={(@operation.input["properties"] || %{}) == %{}}
              class="sub"
              style="margin-bottom: 12px"
            >
              It takes no input.
            </div>
            <Form.fields schema={@operation.input} params={@params} />
            <button
              class={["btn", if(@operation.effect == "destructive", do: "danger", else: "primary")]}
              data-confirm={
                @operation.effect == "destructive" && "Run #{@operation.id}? It can't be undone."
              }
            >
              {if @operation.stream, do: "Follow", else: "Run"}
            </button>
          </form>
        </div>
        <div :if={@error} class="flash error">{@error}</div>
        <div :if={@result} class="card">
          <header>Answer</header>
          <div class="body"><.json value={@result} /></div>
        </div>
        <div :if={@live != nil} class="card">
          <header>Events <.live live={@live} stopped={@stopped} /></header>
          <div class="body">
            <.events events={@events} empty="Waiting for events." dashboard={@dashboard} agent />
          </div>
        </div>
      </div>
      <aside>
        <div class="card">
          <header>About</header>
          <div class="body">
            <p style="margin-top: 0">{@operation.description}</p>
            <dl class="facts">
              <dt>Subject</dt><dd>{@operation.subject}</dd>
              <dt>Permission</dt><dd class="mono">{@operation.action}</dd>
            </dl>
          </div>
        </div>
      </aside>
    </div>
    """
  end
end
