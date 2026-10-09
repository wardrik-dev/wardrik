defmodule WardrikSlack.Socket do
  @moduledoc """
  A Socket Mode connection out to Slack, for one channel's app-level token.

  It finds the bot it posts as, asks Slack for a connection URL, connects,
  and acknowledges every envelope Slack sends. A button press goes to
  `WardrikSlack.Rooms` where it binds a room, and to `WardrikSlack.Answers`
  otherwise; an event, such as the bot being invited into a room, to
  `WardrikSlack.Rooms`. Each is handled in a task of its own, with the
  channel's `:token`, `:context` and `:req_options`, and the bot's user id as
  `:bot`. It starts nothing for a channel with no app-level token.
  When Slack closes the connection, as it does every few hours, or the
  network drops it, it connects again, waiting longer after each failure up
  to a minute.
  """

  use GenServer

  require Logger

  alias WardrikSlack.Socket.Connection

  @first_backoff 1_000
  @max_backoff 60_000

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: {__MODULE__, opts[:name]}, start: {__MODULE__, :start_link, [opts]}}

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts) do
    opts = Keyword.validate!(opts, [:name, :app_token, :token, :context, req_options: []])
    if opts[:app_token], do: GenServer.start_link(__MODULE__, opts), else: :ignore
  end

  @doc """
  What a text frame from Slack asks for: `:hello`, `:disconnect`, an
  envelope to acknowledge with what it carries, or `:ignore`.
  """
  @spec envelope(String.t()) ::
          :hello | :disconnect | {:ack, String.t(), {:interactive, map()} | :ignore} | :ignore
  def envelope(text) do
    case JSON.decode(text) do
      {:ok, %{"type" => "hello"}} ->
        :hello

      {:ok, %{"type" => "disconnect"}} ->
        :disconnect

      {:ok, %{"envelope_id" => id, "type" => "interactive", "payload" => payload}} ->
        {:ack, id, {:interactive, payload}}

      {:ok, %{"envelope_id" => id, "type" => "events_api", "payload" => %{"event" => event}}} ->
        {:ack, id, {:event, event}}

      {:ok, %{"envelope_id" => id}} ->
        {:ack, id, :ignore}

      _other ->
        :ignore
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       token: opts[:app_token],
       answer: Keyword.take(opts, [:token, :context, :req_options]),
       connection: nil,
       backoff: @first_backoff
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  @impl true
  def handle_info(:connect, state), do: connect(state)

  def handle_info(:hello, state), do: {:noreply, %{state | backoff: @first_backoff}}

  def handle_info({:interactive, payload}, state) do
    handler =
      case payload do
        %{"actions" => [%{"action_id" => "wardrik_room" <> _} | _]} -> WardrikSlack.Rooms
        _other -> WardrikSlack.Answers
      end

    Task.Supervisor.start_child(WardrikChannel.tasks(), fn ->
      handler.answer(payload, state.answer)
    end)

    {:noreply, state}
  end

  def handle_info({:event, event}, state) do
    Task.Supervisor.start_child(WardrikChannel.tasks(), fn ->
      WardrikSlack.Rooms.event(event, state.answer)
    end)

    {:noreply, state}
  end

  def handle_info({:EXIT, connection, _reason}, %{connection: connection} = state),
    do: retry(%{state | connection: nil})

  def handle_info(_message, state), do: {:noreply, state}

  # The bot's own user id is found once, before the first connection.
  defp connect(state) do
    if Keyword.has_key?(state.answer, :bot), do: open(state), else: find_bot(state)
  end

  defp find_bot(state) do
    req_options = Keyword.get(state.answer, :req_options, [])

    case WardrikSlack.post("auth.test", state.answer[:token], %{}, req_options) do
      {:ok, %{"user_id" => bot}} ->
        open(%{state | answer: Keyword.put(state.answer, :bot, bot)})

      error ->
        Logger.warning("Slack did not say which bot this channel posts as: #{inspect(error)}")
        retry(state)
    end
  end

  defp open(state) do
    with {:ok, %{"url" => url}} <-
           WardrikSlack.post(
             "apps.connections.open",
             state.token,
             %{},
             Keyword.get(state.answer, :req_options, [])
           ),
         {:ok, connection} <- Connection.start_link(url, self()) do
      {:noreply, %{state | connection: connection}}
    else
      error ->
        Logger.warning("Slack Socket Mode could not connect: #{inspect(error)}")
        retry(state)
    end
  end

  defp retry(state) do
    Process.send_after(self(), :connect, state.backoff)
    {:noreply, %{state | backoff: min(state.backoff * 2, @max_backoff)}}
  end
end

defmodule WardrikSlack.Socket.Connection do
  @moduledoc false

  use WebSockex

  @spec start_link(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_link(url, owner), do: WebSockex.start_link(url, __MODULE__, owner)

  @impl true
  def handle_frame({:text, text}, owner) do
    case WardrikSlack.Socket.envelope(text) do
      :hello ->
        send(owner, :hello)
        {:ok, owner}

      :disconnect ->
        {:close, owner}

      {:ack, id, work} ->
        if work != :ignore, do: send(owner, work)
        {:reply, {:text, JSON.encode!(%{envelope_id: id})}, owner}

      :ignore ->
        {:ok, owner}
    end
  end

  def handle_frame(_frame, owner), do: {:ok, owner}
end
