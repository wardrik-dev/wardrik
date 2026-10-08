defmodule WardrikOAuth.Loopback do
  @moduledoc """
  The pages an authorization server redirects back to, served on loopback by
  Bandit.

      {WardrikOAuth.Supervisor, redirect: [port: 4599]}

  A single binary has nowhere on the public internet to send a code, and RFC
  8252 says a native application should not need one: the browser is on the
  same machine. Each provider has a path of its own, so
  `http://127.0.0.1:4599/callback/github` is the redirect URI to register for
  the `github` provider, and a code that comes back to it finishes only a
  `github` flow.

  It listens on loopback only, and hands a callback's code, `state` and `iss`
  to `WardrikOAuth.finish/3`, answering with a page telling the person to go
  back to their agent. What a server sent that is shown on the page is
  escaped. Anything that is not a callback gets a 404, and a callback
  carrying no code a 400.

  A port another process holds is tried again every five seconds, so of
  several nodes on one machine the first to start listens, and another takes
  the port over when that one stops. `WardrikOAuth.finish/3` finds a flow any
  node of the cluster started.

  A deployment with a web surface of its own registers that instead and calls
  `WardrikOAuth.finish/3` from its own controller; then nothing here runs.
  """

  use GenServer

  require Logger

  @default_port 4599
  @retry :timer.seconds(5)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The redirect URI this listener answers on for `provider`."
  @spec redirect_uri(String.t()) :: String.t()
  def redirect_uri(provider) when is_binary(provider),
    do: "http://127.0.0.1:#{port()}/callback/#{URI.encode(provider, &URI.char_unreserved?/1)}"

  @doc "The port it listens on."
  @spec port() :: :inet.port_number()
  def port, do: Keyword.get(WardrikOAuth.Config.redirect(), :port, @default_port)

  @doc "Where `listener` listens, or `:error` while it cannot."
  @spec listening(GenServer.server()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | :error
  def listening(listener \\ __MODULE__), do: GenServer.call(listener, :listening)

  @impl GenServer
  def init(opts) do
    # Bandit is linked to this process, and says why when it stops.
    Process.flag(:trap_exit, true)

    state = %{
      port: Keyword.get(opts, :port, port()),
      retry: Keyword.get(opts, :retry, @retry),
      server: nil
    }

    {:ok, listen(state, :first)}
  end

  @impl GenServer
  def handle_call(:listening, _from, %{server: nil} = state), do: {:reply, :error, state}

  def handle_call(:listening, _from, %{server: server} = state),
    do: {:reply, ThousandIsland.listener_info(server), state}

  @impl GenServer
  def handle_info(:listen, %{server: nil} = state), do: {:noreply, listen(state, :again)}
  def handle_info(:listen, state), do: {:noreply, state}

  def handle_info({:EXIT, server, reason}, %{server: server} = state) do
    Logger.warning("OAuth loopback stopped listening: #{inspect(reason)}")
    Process.send_after(self(), :listen, state.retry)
    {:noreply, %{state | server: nil}}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  defp listen(%{port: port} = state, attempt) do
    options = [
      plug: WardrikOAuth.Loopback.Page,
      ip: {127, 0, 0, 1},
      port: port,
      startup_log: false
    ]

    case Bandit.start_link(options) do
      {:ok, server} ->
        if attempt == :again, do: Logger.info("OAuth loopback listens on #{port} now")
        %{state | server: server}

      {:error, reason} ->
        if attempt == :first do
          Logger.warning(
            "OAuth loopback could not listen on #{port}: #{inspect(reason)}. " <>
              "It is tried again every #{div(state.retry, 1000)}s"
          )
        end

        Process.send_after(self(), :listen, state.retry)
        state
    end
  end

  @doc """
  What a callback for `provider` carrying `params` is answered with: a status
  and the message shown on the page.
  """
  @spec answer(String.t(), map()) :: {pos_integer(), String.t()}
  def answer(_provider, %{"error" => error} = params),
    do: {400, "#{error}: #{params["error_description"] || "no reason given"}"}

  def answer(provider, %{"code" => code, "state" => state} = params)
      when is_binary(code) and is_binary(state) do
    case WardrikOAuth.finish(state, code, provider: provider, iss: params["iss"]) do
      {:ok, name} ->
        {200, "#{name} is connected. Go back to your agent."}

      {:error, reason} ->
        {400, "That did not work (#{tag(reason)}). Start again from your agent."}
    end
  end

  def answer(_provider, _params), do: {400, "That callback carried no code."}

  defp tag(reason) when is_atom(reason), do: reason
  defp tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp tag(_reason), do: :failed
end
