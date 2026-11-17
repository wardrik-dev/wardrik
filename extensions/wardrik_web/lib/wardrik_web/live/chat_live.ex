defmodule WardrikWeb.ChatLive do
  @moduledoc false
  use Phoenix.LiveView

  import WardrikWeb.Components

  alias Wardrik.Error
  alias WardrikWeb.Follow
  alias WardrikWeb.Timeline

  # How often the agents and the calls waiting on a person are read again, in milliseconds.
  # Agents the open chat doesn't follow, such as a worker it set up, change between reads.
  @refresh 3_000

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, :refresh)

    socket =
      socket
      |> assign(agent: params["agent"], conversation: params["conversation"])
      |> assign(read: nil, items: [], drafts: %{}, waiting: [])
      |> refresh()

    {:ok, open(socket), layout: {WardrikWeb.Layouts, :chat}}
  end

  # The agents to chat with, the calls waiting on a person, and the tab's title, which counts them.
  defp refresh(socket) do
    socket = waiting(chats(socket))
    title = socket.assigns.name || "Chat"

    case length(socket.assigns.waiting) do
      0 -> assign(socket, :page_title, title)
      count -> assign(socket, :page_title, "(#{count}) #{title}")
    end
  end

  defp waiting(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "interrupts.list", %{}) do
      {:ok, %{"interrupts" => interrupts}} -> assign(socket, :waiting, interrupts)
      {:error, error} -> put_flash(socket, :error, error.message)
    end
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
    do: {:noreply, Follow.handle(message, socket, &load/1, on_event: &Timeline.add_draft/2)}

  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  defp load(socket) do
    scope = socket.assigns.scope

    with {:ok, read} <- read(scope, socket.assigns.input),
         {:ok, %{"items" => items}} <-
           Wardrik.Scope.run(scope, "agent.timeline", socket.assigns.input) do
      socket
      |> assign(read: read, items: items)
      |> refresh()
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
            %{id: id, conversations: list(conversations)}
          end)

        ids = Enum.map(chats, & &1.id)
        names = socket.assigns.names.(ids)
        chats = Enum.map(chats, &Map.put(&1, :name, Map.get(names, &1.id, &1.id)))

        socket
        |> assign(:chats, Enum.sort_by(chats, & &1.name))
        |> assign(:agent_names, names)
        |> assign(:name, Map.get(names, socket.assigns.agent, socket.assigns.agent))

      {:error, error} ->
        socket
        |> assign(chats: [], agent_names: %{}, name: socket.assigns.agent)
        |> put_flash(:error, error.message)
    end
  end

  # The agent's own history is the agent's link; its conversations follow, newest first.
  defp list(conversations) do
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
          <button
            id="notify-me"
            class="btn"
            type="button"
            hidden
            phx-update="ignore"
            title="A browser notification when an agent waits for your approval"
          >
            Notify me
          </button>
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
        doing={doing(@read, @drafts)}
        empty={"Ask #{@name} anything."}
      />
      <div class="dock">
        <.elsewhere
          waiting={elsewhere(@waiting, @agent, @conversation)}
          names={@agent_names}
          dashboard={@dashboard}
        />
        <Timeline.composer placeholder={"Message #{@name}"} />
      </div>
      <div
        id="waiting-notify"
        phx-hook="NotifyWaiting"
        data-count={length(@waiting)}
        data-text={notice(@waiting, @agent_names)}
        hidden
      >
      </div>
    </div>
    """
  end

  # What the agent does while a run goes and no answer is streaming in.
  defp doing(%{"status" => "running", "activity" => activity}, drafts) when drafts == %{},
    do: activity

  defp doing(_read, _drafts), do: nil

  defp elsewhere(waiting, agent, conversation),
    do: Enum.reject(waiting, &(&1["agent"]["id"] == agent and &1["conversation"] == conversation))

  defp notice([], _names), do: ""

  defp notice([first | _rest] = waiting, names) do
    agent = first["agent"]["id"]

    case length(waiting) do
      1 -> "#{Map.get(names, agent, agent)} is waiting for your approval."
      count -> "#{count} calls are waiting for your approval."
    end
  end

  attr :waiting, :list, required: true
  attr :names, :map, required: true
  attr :dashboard, :any, required: true

  # Calls waiting on a person in other chats, each a link to its chat.
  defp elsewhere(assigns) do
    ~H"""
    <div :if={@waiting != []} class="elsewhere">
      <.link
        :for={waiting <- @waiting}
        navigate={
          WardrikWeb.path(@dashboard, ["chat", waiting["agent"]["id"]], %{
            "conversation" => waiting["conversation"]
          })
        }
      >
        <b>{Map.get(@names, waiting["agent"]["id"], waiting["agent"]["id"])}</b>
        is waiting for your approval to use
        <code>{Timeline.tool_name(waiting["interrupt"]["name"])}</code>
        <span class="go">Review →</span>
      </.link>
    </div>
    """
  end
end
