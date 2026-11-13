defmodule WardrikWeb.Follow do
  @moduledoc """
  Keeps a LiveView up to date with a streamed operation.

  When events arrive, it reloads the view. It reloads at most once every 250 ms.

      def mount(_params, _session, socket),
        do: {:ok, socket |> load() |> WardrikWeb.Follow.start("events.list", %{})}

      def handle_info({WardrikWeb.Follow, _message} = message, socket),
        do: {:noreply, WardrikWeb.Follow.handle(message, socket, &load/1)}

    * The stream starts only once the LiveView is connected.
    * The stream runs in a task linked to the LiveView. When one exits, the other exits too.
    * `@live` is `true` while the stream is open. When the stream fails or ends, `@live` is
      `false` and `@stopped` gives the reason.
  """

  import Phoenix.Component, only: [assign: 3]

  @wait 250
  # Text deltas and progress updates don't change what a reload shows.
  @quiet ~w(wardrik.message.delta wardrik.reasoning.delta wardrik.tool_call.progress wardrik.subagent.progress)

  @doc """
  Streams events for every agent the scope can see, using `events.list`.

  Agents created later are included the next time the view mounts.
  """
  @spec agents(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def agents(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "agents.list", %{}) do
      {:ok, %{"agents" => [_ | _] = agents}} ->
        ids =
          agents
          |> Enum.map(& &1["id"])
          |> Enum.uniq()

        start(socket, "events.list", %{"agents" => ids})

      _none ->
        socket
        |> assign(:live, false)
        |> assign(:due, false)
        |> assign(:stopped, "No agents to watch.")
    end
  end

  @doc "Starts streaming operation `id` with `input`, in the socket's scope."
  @spec start(Phoenix.LiveView.Socket.t(), String.t(), map()) :: Phoenix.LiveView.Socket.t()
  def start(socket, id, input) do
    if Phoenix.LiveView.connected?(socket) do
      {lv, scope} = {self(), socket.assigns.scope}
      {:ok, _task} = Task.start_link(fn -> follow(lv, scope, id, input) end)

      socket
      |> assign(:live, true)
      |> assign(:due, false)
      |> assign(:stopped, nil)
    else
      socket
      |> assign(:live, false)
      |> assign(:due, false)
      |> assign(:stopped, nil)
    end
  end

  @doc """
  Handles a message sent by the stream.

  It calls `reload` with the socket after events arrive. If you pass `:on_event`, it calls it
  with each event.
  """
  @spec handle({module(), term()}, Phoenix.LiveView.Socket.t(), (term() -> term()), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def handle(message, socket, reload, opts \\ [])

  def handle({__MODULE__, {:event, event}}, socket, _reload, opts) do
    socket = Keyword.get(opts, :on_event, fn _event, socket -> socket end).(event, socket)

    if socket.assigns.due or event["type"] in @quiet do
      socket
    else
      Process.send_after(self(), {__MODULE__, :reload}, @wait)
      assign(socket, :due, true)
    end
  end

  def handle({__MODULE__, :reload}, socket, reload, _opts) do
    socket
    |> assign(:due, false)
    |> reload.()
  end

  def handle({__MODULE__, {:ended, why}}, socket, _reload, _opts) do
    socket
    |> assign(:live, false)
    |> assign(:stopped, why)
  end

  defp follow(lv, scope, id, input) do
    why =
      case Wardrik.Scope.stream(scope, id, input) do
        {:ok, stream} ->
          Enum.each(stream, fn {event, _cursor} -> send(lv, {__MODULE__, {:event, event}}) end)
          "The event stream closed."

        {:error, error} ->
          error.message
      end

    send(lv, {__MODULE__, {:ended, why}})
  end
end
