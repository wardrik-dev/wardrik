defmodule WardrikWeb.OperationLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.Follow
  alias WardrikWeb.Input

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
           fields: Input.fields(operation),
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
  def handle_event("run", params, socket) do
    socket = assign(socket, params: params, error: nil)

    with {:ok, input} <- Input.read(socket.assigns.fields, params),
         {:ok, result} <-
           Wardrik.Scope.run(socket.assigns.scope, socket.assigns.operation.id, input) do
      {:noreply, assign(socket, result: result)}
    else
      {:error, %{message: message}} -> {:noreply, assign(socket, result: nil, error: message)}
      {:error, message} -> {:noreply, assign(socket, result: nil, error: message)}
    end
  end

  def handle_event("follow", params, socket) do
    case Input.read(socket.assigns.fields, params) do
      {:ok, input} ->
        {:noreply,
         socket
         |> assign(params: params, events: [], error: nil)
         |> Follow.start(socket.assigns.operation.id, input)}

      {:error, message} ->
        {:noreply, assign(socket, error: message)}
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

    <div class="layout">
      <div>
        <div class="card">
          <header>Input</header>
          <form class="body" phx-submit={if @operation.stream, do: "follow", else: "run"}>
            <div :if={@fields == []} class="sub" style="margin-bottom: 12px">It takes no input.</div>
            <.field :for={field <- @fields} field={field} value={@params[field.name]} />
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
          <div :if={@events == []} class="empty">Waiting for events.</div>
          <div :for={event <- @events} class="step">
            <div class="tool">
              <code>{event["type"]}</code><span class="sub">{event["agent"]}</span>
            </div>
            <details>
              <summary>data</summary><.json value={event["data"]} />
            </details>
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

  attr :field, Input.Field, required: true
  attr :value, :string, default: nil

  defp field(assigns) do
    ~H"""
    <div class="field">
      <label for={"f-#{@field.name}"}>
        <code>{@field.name}</code><span :if={@field.required} class="req">required</span>
      </label>
      <%= case @field.kind do %>
        <% :choice -> %>
          <select id={"f-#{@field.name}"} name={@field.name}>
            <option value=""></option>
            <option :for={choice <- @field.choices} value={choice} selected={choice == @value}>
              {choice}
            </option>
          </select>
        <% :switch -> %>
          <select id={"f-#{@field.name}"} name={@field.name}>
            <option value=""></option>
            <option value="true" selected={@value == "true"}>true</option>
            <option value="false" selected={@value == "false"}>false</option>
          </select>
        <% :lines -> %>
          <textarea id={"f-#{@field.name}"} name={@field.name} placeholder="One a line">{@value}</textarea>
        <% :json -> %>
          <textarea id={"f-#{@field.name}"} name={@field.name} placeholder="JSON">{@value}</textarea>
        <% kind -> %>
          <input
            id={"f-#{@field.name}"}
            type={if kind == :number, do: "number", else: "text"}
            name={@field.name}
            value={@value}
            step="any"
          />
      <% end %>
      <div :if={@field.description} class="hint">{@field.description}</div>
    </div>
    """
  end
end
