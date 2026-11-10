defmodule WardrikWeb.Follow do
  @moduledoc """
  Follows a streamed operation for a LiveView, and reloads the view at most every 250 ms while
  events arrive.

      def mount(_params, _session, socket),
        do: {:ok, socket |> load() |> WardrikWeb.Follow.start("events.list", %{})}

      def handle_info({WardrikWeb.Follow, _message} = message, socket),
        do: {:noreply, WardrikWeb.Follow.handle(message, socket, &load/1)}

    * It follows only once the LiveView is connected.
    * The stream runs in a task linked to the LiveView, so each ends with the other.
    * `@live` is `true` while it follows. Once the stream fails or ends, it's `false` and
      `@stopped` says why.
  """

  import Phoenix.Component, only: [assign: 3]

  @wait 250
  # Streamed text and progress change nothing a reload reads.
  @quiet ~w(wardrik.message.delta wardrik.reasoning.delta wardrik.tool_call.progress wardrik.subagent.progress)

  @doc """
  Starts following every agent the socket's scope may see, with `events.list`. Agents defined
  later are followed once the view mounts again.
  """
  @spec agents(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def agents(socket) do
    case Wardrik.Scope.run(socket.assigns.scope, "agents.list", %{}) do
      {:ok, %{"agents" => [_ | _] = agents}} ->
        start(socket, "events.list", %{"agents" => agents |> Enum.map(& &1["id"]) |> Enum.uniq()})

      _none ->
        socket
        |> assign(:live, false)
        |> assign(:due, false)
        |> assign(:stopped, "No agents to watch.")
    end
  end

  @doc "Starts following operation `id` with `input`, in the socket's scope."
  @spec start(Phoenix.LiveView.Socket.t(), String.t(), map()) :: Phoenix.LiveView.Socket.t()
  def start(socket, id, input) do
    if Phoenix.LiveView.connected?(socket) do
      {lv, scope} = {self(), socket.assigns.scope}
      {:ok, _task} = Task.start_link(fn -> follow(lv, scope, id, input) end)
      socket |> assign(:live, true) |> assign(:due, false) |> assign(:stopped, nil)
    else
      socket |> assign(:live, false) |> assign(:due, false) |> assign(:stopped, nil)
    end
  end

  @doc """
  Handles a message `start/3` sent. Calls `reload` with the socket when events have arrived, and
  `on_event` with each event, if given.
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

  def handle({__MODULE__, :reload}, socket, reload, _opts),
    do: socket |> assign(:due, false) |> reload.()

  def handle({__MODULE__, {:ended, why}}, socket, _reload, _opts),
    do: socket |> assign(:live, false) |> assign(:stopped, why)

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
