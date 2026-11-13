defmodule WardrikWeb.TriggersComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  import WardrikWeb.Components

  alias WardrikWeb.Form

  @schema WardrikProtocol.operation("agent.trigger_set").input
  # The page sets the agent. The `trigger` field holds the name.
  @elsewhere ~w(agent name)

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, triggers: nil, next_runs: %{}, editing: nil, params: %{})}

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(socket.assigns.triggers, do: socket, else: load(socket))}
  end

  defp load(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "agent.definition", %{
           "agent" => socket.assigns.agent
         }) do
      {:ok, %{"definition" => definition} = answer} ->
        assign(socket,
          triggers: definition["triggers"] || [],
          next_runs: answer["next_runs"] || %{}
        )

      {:error, error} ->
        socket
        |> assign(triggers: [])
        |> flash(:error, error.message)
    end
  end

  @impl true
  def handle_event("new", _params, socket),
    do: {:noreply, assign(socket, editing: :new, params: %{})}

  def handle_event("edit", %{"name" => name}, socket) do
    trigger = Enum.find(socket.assigns.triggers, &(&1["name"] == name))
    params = Form.params(@schema, Map.put(trigger, "trigger", name))
    {:noreply, assign(socket, editing: name, params: params)}
  end

  def handle_event("cancel", _params, socket),
    do: {:noreply, assign(socket, editing: nil, params: %{})}

  def handle_event("change", %{"input" => params}, socket),
    do: {:noreply, assign(socket, :params, params)}

  def handle_event("save", %{"input" => params}, socket) do
    with {:ok, trigger} <- read(params),
         {:ok, _answer} <-
           Wardrik.Scope.run(
             socket.assigns.scope,
             "agent.trigger_set",
             Map.put(trigger, "agent", socket.assigns.agent)
           ) do
      # A rename saves the trigger under its new name. Remove the old one.
      if is_binary(socket.assigns.editing) and socket.assigns.editing != trigger["trigger"],
        do: remove(socket, socket.assigns.editing)

      {:noreply,
       socket
       |> assign(editing: nil, triggers: nil)
       |> load()
       |> flash(:info, "Saved #{trigger["trigger"]}.")}
    else
      {:error, %{message: message}} -> {:noreply, flash(socket, :error, message)}
      {:error, message} -> {:noreply, flash(socket, :error, message)}
    end
  end

  def handle_event("remove", %{"name" => name}, socket) do
    case remove(socket, name) do
      {:ok, _answer} ->
        socket =
          socket
          |> assign(triggers: nil)
          |> load()
          |> flash(:info, "Removed #{name}.")

        {:noreply, socket}

      {:error, error} ->
        {:noreply, flash(socket, :error, error.message)}
    end
  end

  def handle_event(event, value, socket),
    do: {:noreply, assign(socket, :params, Form.handle(event, value, socket.assigns.params))}

  defp remove(socket, name),
    do:
      Wardrik.Scope.run(socket.assigns.scope, "agent.trigger_remove", %{
        "agent" => socket.assigns.agent,
        "trigger" => name
      })

  defp read(params) do
    case Form.read(@schema, params) do
      {:ok, %{"trigger" => _name} = trigger} -> {:ok, trigger}
      {:ok, _trigger} -> {:error, "Enter a trigger name."}
      :none -> {:error, "Enter a trigger name."}
      {:error, _why} = error -> error
    end
  end

  defp kind(%{"webhook" => _}), do: "webhook"
  defp kind(%{"feed" => _}), do: "feed"
  defp kind(_trigger), do: "clock"

  defp when_text(%{"webhook" => _} = trigger, agent),
    do: "POST /v1/hooks/#{URI.encode(agent, &URI.char_unreserved?/1)}/#{trigger["name"]}"

  defp when_text(%{"feed" => feed} = trigger, _agent),
    do:
      Enum.join(
        [
          Enum.join(List.wrap(feed), ", ")
          | List.wrap(trigger["every"] && "every #{trigger["every"]}")
        ],
        " · "
      )

  defp when_text(trigger, _agent),
    do: Enum.join(Enum.reject([trigger["every"], trigger["timezone"]], &is_nil/1), " · ")

  @impl true
  def render(assigns) do
    assigns = assign(assigns, schema: @schema, elsewhere: @elsewhere)

    ~H"""
    <div>
      <div class="card">
        <header>
          Triggers
          <button :if={!@editing} class="btn small primary" phx-click="new" phx-target={@myself}>Add trigger</button>
        </header>
        <table :if={@triggers != []} class="list stack">
          <thead>
            <tr>
              <th>Name</th><th>Kind</th><th>When</th><th>Next run</th><th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={trigger <- @triggers || []}>
              <td class="lead">
                <b>{trigger["name"]}</b>
                <div :if={trigger["prompt"] || trigger["prompt_file"]} class="sub">
                  {trigger["prompt"] || "reads #{trigger["prompt_file"]}"}
                </div>
              </td>
              <td data-label="Kind"><span class="tag">{kind(trigger)}</span></td>
              <td data-label="When"><code>{when_text(trigger, @agent)}</code></td>
              <td data-label="Next run" class="when">{ago(@next_runs[trigger["name"]])}</td>
              <td class="num">
                <span class="actions" style="justify-content: flex-end">
                  <button
                    class="btn small"
                    phx-click="edit"
                    phx-value-name={trigger["name"]}
                    phx-target={@myself}
                  >Edit</button>
                  <button
                    class="btn small danger"
                    phx-click="remove"
                    phx-value-name={trigger["name"]}
                    phx-target={@myself}
                    data-confirm={"Remove #{trigger["name"]}?"}
                  >
                    Remove
                  </button>
                </span>
              </td>
            </tr>
          </tbody>
        </table>
        <div :if={@triggers == [] and !@editing} class="empty">
          No triggers. The agent runs only when it receives a message.
        </div>
      </div>

      <form
        :if={@editing}
        id="trigger-form"
        class="card"
        phx-change="change"
        phx-submit="save"
        phx-target={@myself}
      >
        <header>
          {if @editing == :new, do: "New trigger", else: "Edit #{@editing}"}
          <span class="actions">
            <button type="button" class="btn small" phx-click="cancel" phx-target={@myself}>Cancel</button>
            <button class="btn small primary">Save</button>
          </span>
        </header>
        <div class="body">
          <p class="sub" style="margin-top: 0">
            Set <code>every</code>
            for a schedule, <code>feed</code>
            for RSS or Atom feeds, or <code>webhook</code>
            for incoming requests.
          </p>
          <Form.fields
            schema={@schema}
            params={@params}
            only={~w(trigger prompt every timezone feed webhook prompt_file overlap missed jitter)}
            except={@elsewhere}
            target={@myself}
          />
        </div>
      </form>
    </div>
    """
  end
end
