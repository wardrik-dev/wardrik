defmodule WardrikSlack.Socket do
  @moduledoc """
  Connects to Slack over Socket Mode with the channel's `:app_token`. For testing; use
  `WardrikSlack.HTTP` in production.

    * Messages are acknowledged once handled, so Slack resends one lost to a crash.
    * Reconnects when the connection closes, with backoff up to a minute.
  """

  use GenServer

  alias Wardrik.Chat.Channel
  alias WardrikSlack.API
  alias WardrikSlack.Dispatch
  alias WardrikSlack.Socket.Connection

  require Logger

  @first_backoff 1_000
  @max_backoff 60_000

  @doc "Starts the connection for `channel`."
  @spec start_link(Channel.t()) :: GenServer.on_start()
  def start_link(%Channel{} = channel), do: GenServer.start_link(__MODULE__, channel)

  @doc """
  Parses a text frame from Slack.

  Returns `:hello`, `:disconnect`, `{:ack, id, work}` to acknowledge now,
  `{:ack_after, id, {:message, callback}}` to acknowledge once handled, or `:ignore`.
  """
  @spec envelope(String.t()) ::
          :hello
          | :disconnect
          | {:ack, String.t(), {:interactive, map()} | {:event, map()} | :ignore}
          | {:ack_after, String.t(), {:message, map()}}
          | :ignore
  def envelope(text) do
    case JSON.decode(text) do
      {:ok, %{"type" => "hello"}} -> :hello
      {:ok, %{"type" => "disconnect"}} -> :disconnect
      {:ok, %{"envelope_id" => id} = envelope} -> carried(id, envelope)
      _other -> :ignore
    end
  end

  defp carried(id, %{"type" => "interactive", "payload" => payload}),
    do: {:ack, id, {:interactive, payload}}

  defp carried(id, %{
         "type" => "events_api",
         "payload" => %{"event" => %{"type" => "message"}} = callback
       }),
       do: {:ack_after, id, {:message, callback}}

  defp carried(id, %{"type" => "events_api", "payload" => %{"event" => _event} = callback}),
    do: {:ack, id, {:event, callback}}

  defp carried(id, _envelope), do: {:ack, id, :ignore}

  @impl GenServer
  def init(channel) do
    Process.flag(:trap_exit, true)
    {:ok, %{channel: channel, connection: nil, backoff: @first_backoff}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: connect(state)

  @impl GenServer
  def handle_info(:connect, state), do: connect(state)
  def handle_info(:hello, state), do: {:noreply, %{state | backoff: @first_backoff}}

  def handle_info({:interactive, payload}, state),
    do: run(state, fn -> Dispatch.interactive(state.channel, payload) end)

  def handle_info({:event, callback}, state),
    do: run(state, fn -> Dispatch.event(state.channel, callback) end)

  def handle_info({:message, callback, {connection, id}}, state) do
    run(state, fn ->
      Dispatch.event(state.channel, callback)
      Connection.ack(connection, id)
    end)
  end

  def handle_info({:EXIT, connection, _reason}, %{connection: connection} = state),
    do: retry(%{state | connection: nil})

  def handle_info(_message, state), do: {:noreply, state}

  defp run(state, work) do
    tasks = WardrikSlack.tasks(state.channel)
    {:ok, _pid} = Task.Supervisor.start_child(tasks, work)
    {:noreply, state}
  end

  defp connect(%{channel: channel} = state) do
    token = Keyword.fetch!(channel.options, :app_token)

    with {:ok, %{"url" => url}} <-
           API.post("apps.connections.open",
             token: token,
             body: %{},
             req_options: API.req_options(channel)
           ),
         {:ok, connection} <- Connection.start_link(url, self()) do
      {:noreply, %{state | connection: connection}}
    else
      error ->
        Logger.warning("Slack's Socket Mode didn't connect: #{inspect(error)}")
        retry(state)
    end
  end

  defp retry(state) do
    Process.send_after(self(), :connect, state.backoff)
    {:noreply, %{state | backoff: min(state.backoff * 2, @max_backoff)}}
  end
end
