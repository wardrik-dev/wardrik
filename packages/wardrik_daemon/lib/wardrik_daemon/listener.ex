defmodule WardrikDaemon.Listener do
  @moduledoc """
  Serves with Bandit on a port other nodes on this machine share. The first to start listens. The
  rest try again every `:retry` milliseconds, so one takes the port over when that node stops.

      {WardrikDaemon.Listener, bandit: [plug: MyPlug, port: 4747], retry: 5_000}
  """

  use GenServer

  require Logger

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Starts it. Returns at once, listening or not."
  @spec start_link(bandit: keyword(), retry: pos_integer()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @impl GenServer
  def init(%{bandit: bandit, retry: retry}) do
    # Bandit is linked to this process. Its exit means the port is free to try for again.
    Process.flag(:trap_exit, true)
    {:ok, listen(%{bandit: bandit, retry: retry, server: nil}, :first)}
  end

  @impl GenServer
  def handle_info(:listen, %{server: nil} = state), do: {:noreply, listen(state, :again)}

  def handle_info({:EXIT, server, reason}, %{server: server} = state) do
    Logger.warning("The HTTP API stopped listening: #{inspect(reason)}")
    {:noreply, retried(%{state | server: nil})}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  defp listen(state, attempt) do
    with :ok <- free(state.bandit),
         {:ok, server} <- Bandit.start_link([startup_log: false] ++ state.bandit) do
      Logger.info("The HTTP API listens on port #{state.bandit[:port]}")
      %{state | server: server}
    else
      {:error, reason} ->
        if attempt == :first,
          do:
            Logger.warning(
              "Another node holds port #{state.bandit[:port]} (#{inspect(reason)}). " <>
                "This one takes it over when that one stops."
            )

        retried(state)
    end
  end

  # Bandit logs an error each time it can't listen, so the port is tried first.
  defp free(bandit) do
    opts = [ip: Keyword.get(bandit, :ip, {0, 0, 0, 0}), reuseaddr: true]

    port = Keyword.get(bandit, :port, 4000)

    with {:ok, socket} <- :gen_tcp.listen(port, opts),
         do: :gen_tcp.close(socket)
  end

  defp retried(state) do
    Process.send_after(self(), :listen, state.retry)
    state
  end
end
