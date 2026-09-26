defmodule WardrikHTTP.Listener do
  @moduledoc """
  Serves `WardrikHTTP.Router` with Bandit, where `WardrikHTTP.Config` says to.

  A port another process holds is tried again every five seconds, so of
  several nodes of a cluster on one machine the first to start serves the API,
  and another takes the port over when that one stops. Options:

    * `:port`, `:ip` - over `WardrikHTTP.Config.listen/0`; port `0` takes any free one
    * `:definition` - the `WardrikHTTP.Definition` that
      `PUT /v1/agents/{org}/{user}/{name}` reads a definition with
    * `:retry` - milliseconds between tries, 5000 by default
    * `:name` - the process's name, `WardrikHTTP.Listener` by default
  """

  use GenServer

  require Logger

  @retry :timer.seconds(5)

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The port the listener serves on, or `:error` while it cannot listen."
  @spec port(GenServer.server()) :: {:ok, :inet.port_number()} | :error
  def port(listener \\ __MODULE__), do: GenServer.call(listener, :port)

  @impl GenServer
  def init(opts) do
    # Bandit is linked to this process, and says why when it stops.
    Process.flag(:trap_exit, true)

    listen = Keyword.merge(WardrikHTTP.Config.listen(), Keyword.take(opts, [:port, :ip]))

    state = %{
      listen: listen,
      router: Keyword.take(opts, [:definition]),
      retry: Keyword.get(opts, :retry, @retry),
      server: nil
    }

    {:ok, listen(state, :first)}
  end

  @impl GenServer
  def handle_call(:port, _from, %{server: nil} = state), do: {:reply, :error, state}

  def handle_call(:port, _from, %{server: server} = state) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:reply, {:ok, port}, state}
  end

  @impl GenServer
  def handle_info(:listen, %{server: nil} = state), do: {:noreply, listen(state, :again)}

  def handle_info({:EXIT, server, reason}, %{server: server} = state) do
    Logger.warning("The HTTP API stopped listening: #{inspect(reason)}")
    {:noreply, retry(%{state | server: nil})}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  defp listen(state, attempt) do
    options = [plug: {WardrikHTTP.Router, state.router}, startup_log: false] ++ state.listen

    case Bandit.start_link(options) do
      {:ok, server} ->
        Logger.info("The HTTP API listens on #{where(state)}")
        %{state | server: server}

      {:error, reason} ->
        if attempt == :first do
          Logger.warning(
            "The HTTP API could not listen on #{where(state)}: #{inspect(reason)}. " <>
              "It is tried again every #{div(state.retry, 1000)}s"
          )
        end

        retry(state)
    end
  end

  defp retry(state) do
    Process.send_after(self(), :listen, state.retry)
    state
  end

  defp where(%{listen: listen}), do: "#{:inet.ntoa(listen[:ip])}:#{listen[:port]}"
end
