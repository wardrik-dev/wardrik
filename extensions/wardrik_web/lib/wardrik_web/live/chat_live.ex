defmodule WardrikWeb.ChatLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias Wardrik.Error
  alias WardrikWeb.Follow
  alias WardrikWeb.Timeline

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(agent: params["agent"], conversation: params["conversation"])
      |> assign(read: nil, items: [], drafts: %{})
      |> chats()

    socket = assign(socket, :page_title, socket.assigns.name || "Chat")

    {:ok, open(socket), layout: {WardrikWeb.Layouts, :chat}}
  end

  # With one agent to chat with, the chat page opens it.
  defp open(%{assigns: %{agent: nil, chats: [%{id: agent}]}} = socket),
    do: push_navigate(socket, to: WardrikWeb.path(socket.assigns.dashboard, ["chat", agent]))

  defp open(%{assigns: %{agent: nil}} = socket), do: assign(socket, live: false, stopped: nil)

  defp open(socket) do
    input =
      Map.reject(
        %{"agent" => socket.assigns.agent, "conversation" => socket.assigns.conversation},
        &is_nil(elem(&1, 1))
      )

    socket
    |> assign(:input, input)
    |> load()
    |> Follow.start("agent.events", input)
  end

  @impl true
  def handle_event(event, params, socket) when event in ~w(ask approve deny),
    do: {:noreply, Timeline.handle_event(event, params, socket, &load/1)}

  def handle_event("cancel", _params, socket),
    do: {:noreply, Timeline.act(socket, "agent.cancel", %{}, nil, &load/1)}

  def handle_event("new", _params, socket) do
    path =
      WardrikWeb.path(socket.assigns.dashboard, ["chat", socket.assigns.agent], %{
        "conversation" => new()
      })

    {:noreply, push_navigate(socket, to: path)}
  end

  @impl true
  def handle_info({Follow, _message} = message, socket),
    do: {:noreply, Follow.handle(message, socket, &load/1, on_event: &Timeline.drafted/2)}

  defp load(socket) do
    scope = socket.assigns.scope

    with {:ok, read} <- read(scope, socket.assigns.input),
         {:ok, %{"items" => items}} <-
           Wardrik.Scope.run(scope, "agent.timeline", socket.assigns.input) do
      assign(socket, read: read, items: items)
    else
      {:error, error} -> put_flash(socket, :error, error.message)
    end
  end

  # A conversation no one has written in yet isn't there to read.
  defp read(scope, %{"conversation" => _conversation} = input) do
    case Wardrik.Scope.run(scope, "agent.read", input) do
      {:error, %Error{type: :not_found}} -> {:ok, nil}
      read -> read
    end
  end

  defp read(scope, input), do: Wardrik.Scope.run(scope, "agent.read", input)

  defp chats(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "agents.list", %{}) do
      {:ok, %{"agents" => agents}} ->
        # The open chat is listed before its first message too.
        open = %{"id" => socket.assigns.agent, "conversation" => socket.assigns.conversation}

        chats =
          (agents ++ [open])
          |> Enum.reject(&is_nil(&1["id"]))
          |> Enum.group_by(& &1["id"], & &1["conversation"])
          |> Enum.map(fn {id, conversations} ->
            %{id: id, conversations: listed(conversations)}
          end)

        ids = Enum.map(chats, & &1.id)
        names = socket.assigns.names.(ids)
        chats = Enum.map(chats, &Map.put(&1, :name, Map.get(names, &1.id, &1.id)))

        socket
        |> assign(:chats, Enum.sort_by(chats, & &1.name))
        |> assign(:name, Map.get(names, socket.assigns.agent, socket.assigns.agent))

      {:error, error} ->
        socket
        |> assign(chats: [], name: socket.assigns.agent)
        |> put_flash(:error, error.message)
    end
  end

  # The agent's own history is the agent's link; its conversations follow, newest first.
  defp listed(conversations) do
    conversations
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort(:desc)
  end

  # Sorted newest first, as the list shows them.
  defp new do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")
    "web #{stamp} #{Base.encode32(:crypto.strong_rand_bytes(2), case: :lower, padding: false)}"
  end

  @impl true
  def render(%{agent: nil} = assigns) do
    ~H"""
    <.head title="Chat" lead="Pick an agent to chat with." />
    <div :if={@chats == []} class="card empty">
      There's no agent to chat with yet.
    </div>
    <div :if={@chats != []} class="card">
      <table class="list">
        <tbody>
          <tr :for={chat <- @chats}>
            <td class="lead">
              <.link navigate={WardrikWeb.path(@dashboard, ["chat", chat.id])}>{chat.name}</.link>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="chat-page">
      <.head title={@name} lead={@read && @read["description"]}>
        <:badge :if={@read}><.status value={@read["status"]} /></:badge>
        <:actions>
          <.live live={@live} stopped={@stopped} />
          <button :if={@read && @read["status"] == "running"} class="btn" phx-click="cancel">Stop</button>
          <.link
            class="btn"
            navigate={
              WardrikWeb.path(@dashboard, ["agents", @agent], %{"conversation" => @conversation})
            }
          >Details</.link>
        </:actions>
      </.head>
      <Timeline.timeline
        items={@items}
        drafts={@drafts}
        chat={true}
        empty={"Ask #{@name} anything."}
      />
      <div class="dock"><Timeline.composer placeholder={"Message #{@name}"} /></div>
    </div>
    """
  end
end
