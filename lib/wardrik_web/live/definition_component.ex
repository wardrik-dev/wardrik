defmodule WardrikWeb.DefinitionComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  import WardrikWeb.Components

  alias WardrikWeb.Form

  @schema WardrikProtocol.operation("agent.define").input
  @common ~w(model instructions tools display_name description)
  # Triggers have their own tab; the agent is the page's.
  @elsewhere ~w(agent triggers)

  def common, do: @common

  def schema, do: @schema

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, params: nil, current: nil, missing: [], editing: false)}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(socket.assigns.current, do: socket, else: load(socket))}
  end

  defp load(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "agent.definition", %{
           "agent" => socket.assigns.agent
         }) do
      {:ok, %{"definition" => definition} = answer} ->
        assign(socket,
          current: definition,
          missing: answer["missing"] || [],
          params: Form.params(@schema, definition)
        )

      {:error, error} ->
        assign(socket, current: %{}, params: %{}, error: error.message)
    end
  end

  @impl true
  def handle_event("change", %{"input" => params}, socket),
    do: {:noreply, assign(socket, :params, params)}

  def handle_event("change", _params, socket), do: {:noreply, socket}
  def handle_event("edit", _params, socket), do: {:noreply, assign(socket, :editing, true)}

  def handle_event("discard", _params, socket),
    do:
      {:noreply,
       assign(socket, editing: false, params: Form.params(@schema, socket.assigns.current))}

  def handle_event("save", params, socket) do
    with {:ok, definition} <- read(params["input"]),
         definition = Map.merge(definition, Map.take(socket.assigns.current, ["triggers"])),
         {:ok, _answer} <-
           Wardrik.Scope.run(
             socket.assigns.scope,
             "agent.define",
             Map.put(definition, "agent", socket.assigns.agent)
           ) do
      {:noreply,
       socket
       |> assign(current: nil, editing: false)
       |> load()
       |> put_flash(:info, "Saved the definition.")}
    else
      {:error, %{message: message}} -> {:noreply, put_flash(socket, :error, message)}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event(event, value, socket),
    do: {:noreply, assign(socket, :params, Form.handle(event, value, socket.assigns.params))}

  defp read(params) do
    case Form.read(@schema, params || %{}) do
      {:ok, definition} -> {:ok, definition}
      :none -> {:ok, %{}}
      {:error, _why} = error -> error
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, common: @common, elsewhere: @elsewhere, schema: @schema)

    ~H"""
    <div>
      <div :if={@missing != []} class="flash info">
        Named but not offered yet: {Enum.join(@missing, ", ")}. They start working once they're added.
      </div>
      <form
        :if={@editing}
        id="definition-form"
        class="card"
        phx-change="change"
        phx-submit="save"
        phx-target={@myself}
      >
        <header>
          Definition
          <span class="actions">
            <button type="button" class="btn small" phx-click="discard" phx-target={@myself}>Discard</button>
            <button class="btn small primary">Save</button>
          </span>
        </header>
        <div class="body">
          <Form.fields schema={@schema} params={@params} only={@common} target={@myself} />
          <details class="group" open={false}>
            <summary><b>More settings</b></summary>
            <Form.fields
              schema={@schema}
              params={@params}
              except={@common ++ @elsewhere}
              target={@myself}
            />
          </details>
        </div>
      </form>
      <div :if={!@editing && @current} class="card">
        <header>
          Definition <button class="btn small" phx-click="edit" phx-target={@myself}>Edit</button>
        </header>
        <div class="body">
          <dl class="facts definition">
            <%= for name <- @common, value = @current[name], value not in [nil, "", []] do %>
              <dt>{name}</dt>
              <dd class={name == "instructions" && "prose"}>{shown(value)}</dd>
            <% end %>
          </dl>
          <details style="margin-top: 14px">
            <summary>Everything, as JSON</summary>
            <.json value={Map.drop(@current, ["triggers"])} />
          </details>
        </div>
      </div>
    </div>
    """
  end

  defp shown(value) when is_list(value), do: Enum.join(value, ", ")
  defp shown(value), do: value
end
