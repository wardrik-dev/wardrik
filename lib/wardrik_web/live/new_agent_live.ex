defmodule WardrikWeb.NewAgentLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias WardrikWeb.DefinitionComponent
  alias WardrikWeb.Form

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, page_title: "New agent", id: "", params: %{}, error: nil)}

  @impl true
  def handle_event("change", params, socket),
    do: {:noreply, assign(socket, id: params["agent_id"] || "", params: params["input"] || %{})}

  def handle_event("create", params, socket) do
    id = String.trim(params["agent_id"] || "")
    schema = DefinitionComponent.schema()

    with :ok <- named(id),
         {:ok, definition} <- definition(Form.read(schema, params["input"] || %{})),
         {:ok, _answer} <-
           Wardrik.Scope.run(
             socket.assigns.scope,
             "agent.define",
             Map.put(definition, "agent", id)
           ) do
      {:noreply,
       socket
       |> put_flash(:info, "Defined #{id}.")
       |> push_navigate(
         to: WardrikWeb.path(socket.assigns.dashboard, ["agents", id], %{"tab" => "definition"})
       )}
    else
      {:error, %{message: message}} -> {:noreply, assign(socket, error: message)}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  def handle_event(event, value, socket),
    do: {:noreply, assign(socket, :params, Form.handle(event, value, socket.assigns.params))}

  defp named(""), do: {:error, "Enter an agent ID."}
  defp named(_id), do: :ok

  defp definition({:ok, definition}), do: {:ok, definition}
  defp definition(:none), do: {:ok, %{}}
  defp definition({:error, _why} = error), do: error

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, schema: DefinitionComponent.schema(), common: DefinitionComponent.common())

    ~H"""
    <.head title="New agent" lead="Create an agent from a definition.">
      <:crumb><.link navigate={WardrikWeb.path(@dashboard, [])}>Agents</.link> /</:crumb>
    </.head>
    <div :if={@error} class="flash error" role="alert">{@error}</div>
    <form id="new-agent" class="card" phx-change="change" phx-submit="create">
      <div class="body">
        <div class="field">
          <label for="f-id"><code>id</code><span class="req">required</span></label>
          <input id="f-id" type="text" name="agent_id" value={@id} autocomplete="off" />
          <div class="hint">The new agent's ID.</div>
        </div>
        <Form.fields schema={@schema} params={@params} only={@common} />
        <details class="group">
          <summary><b>More settings</b></summary>
          <Form.fields schema={@schema} params={@params} except={@common ++ ["agent"]} />
        </details>
        <button class="btn primary">Create agent</button>
      </div>
    </form>
    """
  end
end
