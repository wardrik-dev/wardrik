defmodule WardrikNotify.Slack.Socket do
  @moduledoc """
  A Socket Mode connection out to Slack, for one app-level token.

  It asks Slack for a connection URL, connects, acknowledges every envelope
  Slack sends, and hands each button press to `WardrikNotify.Slack.answer/1`.
  When Slack closes the connection, as it does every few hours, or the
  network drops it, it connects again, waiting longer after each failure up
  to a minute.
  """

  use GenServer

  require Logger

  alias WardrikNotify.Slack.Socket.Connection

  @first_backoff 1_000
  @max_backoff 60_000

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    token = Keyword.fetch!(opts, :app_token)
    %{id: {__MODULE__, :erlang.phash2(token)}, start: {__MODULE__, :start_link, [token]}}
  end

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(token), do: GenServer.start_link(__MODULE__, token)

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

      {:ok, %{"envelope_id" => id}} ->
        {:ack, id, :ignore}

      _other ->
        :ignore
    end
  end

  @impl true
  def init(token) do
    Process.flag(:trap_exit, true)
    {:ok, %{token: token, connection: nil, backoff: @first_backoff}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: connect(state)

  @impl true
  def handle_info(:connect, state), do: connect(state)

  def handle_info(:hello, state), do: {:noreply, %{state | backoff: @first_backoff}}

  def handle_info({:interactive, payload}, state) do
    Task.Supervisor.start_child(WardrikNotify.TaskSupervisor, fn ->
      WardrikNotify.Slack.answer(payload)
    end)

    {:noreply, state}
  end

  def handle_info({:EXIT, connection, _reason}, %{connection: connection} = state),
    do: retry(%{state | connection: nil})

  def handle_info(_message, state), do: {:noreply, state}

  defp connect(state) do
    with {:ok, %{"url" => url}} <-
           WardrikNotify.Slack.post("apps.connections.open", state.token, %{}),
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

defmodule WardrikNotify.Slack.Socket.Connection do
  @moduledoc false

  use WebSockex

  @spec start_link(String.t(), pid()) :: {:ok, pid()} | {:error, term()}
  def start_link(url, owner), do: WebSockex.start_link(url, __MODULE__, owner)

  @impl true
  def handle_frame({:text, text}, owner) do
    case WardrikNotify.Slack.Socket.envelope(text) do
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
