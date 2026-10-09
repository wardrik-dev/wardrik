defmodule WardrikOAuth.Callback do
  @moduledoc """
  The page an authorization server sends a browser back to, served by
  Bandit.

      {WardrikOAuth.Supervisor, redirect: [url: "https://agents.example.com/oauth"]}

  Each provider has a path of its own under the deployment's redirect URL,
  so `https://agents.example.com/oauth/callback/github` is the redirect URI
  to register for the `github` provider, and a code that comes back to it
  finishes only a `github` flow.

  Without a URL it is this machine's loopback, `http://127.0.0.1:4599`, as
  RFC 8252 has a native application do: the browser is on the same machine,
  and the link is opened in it. With one, the deployment serves the URL over
  HTTPS from something in front, such as Caddy, which sends the requests
  under it here. It listens where `:ip` and `:port` say, loopback and 4599 by
  default, and serves the URL's own path, so the front passes requests on as
  they came.

  It hands a callback's code, `state` and `iss` to `WardrikOAuth.finish/3`,
  answering with a page telling the person to go back to their agent. What a
  server sent that is shown on the page is escaped. `check` answers with the
  nonce it was sent, so `check/2` can tell that the URL reaches this
  listener. Anything else, and a callback for a provider not configured,
  gets a 404, and a callback carrying no code a 400. Every page is kept from
  caches, referrers and frames, and loads nothing.

  A port another process holds is tried again every five seconds, so of
  several nodes on one machine the first to start listens, and another takes
  the port over when that one stops. `WardrikOAuth.finish/3` finds a flow any
  node of the cluster started.

  A deployment with a web surface of its own serves the callback there
  instead, calling `WardrikOAuth.finish/3` from its own controller, and starts
  `WardrikOAuth.Supervisor` with `callback: false`.
  """

  use GenServer

  require Logger

  @default_port 4599
  @loopback {127, 0, 0, 1}
  @retry :timer.seconds(5)
  @nonce ~r/\A[A-Za-z0-9_-]{1,64}\z/

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The redirect URI this listener answers on for `provider`."
  @spec redirect_uri(String.t()) :: String.t()
  def redirect_uri(provider) when is_binary(provider),
    do: url() <> "/callback/" <> URI.encode(provider, &URI.char_unreserved?/1)

  @doc """
  The deployment's redirect URL, which every provider's redirect URI is
  under: the one configured, or this machine's loopback.
  """
  @spec url() :: String.t()
  def url do
    case Keyword.get(WardrikOAuth.Config.redirect(), :url) do
      nil -> "http://127.0.0.1:#{port()}"
      url -> String.trim_trailing(url, "/")
    end
  end

  @doc "Whether the browser comes back to this machine: no URL is configured, or it names loopback."
  @spec loopback?() :: boolean()
  def loopback? do
    case Keyword.get(WardrikOAuth.Config.redirect(), :url) do
      nil -> true
      url -> URI.parse(url).host in ["127.0.0.1", "localhost", "::1"]
    end
  end

  @doc "The path segments every page is served under: the redirect URL's own."
  @spec prefix() :: [String.t()]
  def prefix,
    do: url() |> URI.parse() |> Map.get(:path) |> to_string() |> String.split("/", trim: true)

  @doc "The port it listens on."
  @spec port() :: :inet.port_number()
  def port, do: Keyword.get(WardrikOAuth.Config.redirect(), :port, @default_port)

  @doc "The address it listens on."
  @spec ip() :: :inet.ip_address()
  def ip, do: Keyword.get(WardrikOAuth.Config.redirect(), :ip, @loopback)

  @doc """
  Whether `url`, the deployment's redirect URL, reaches this listener: asks
  its `check` page with a nonce of its own, through whatever is in front.
  `req_options` are merged into the request.
  """
  @spec check(String.t(), keyword()) :: :ok | {:error, String.t()}
  def check(url, req_options \\ []) do
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    target = String.trim_trailing(url, "/") <> "/check?nonce=" <> nonce

    case Req.get(target, Keyword.merge([retry: false, redirect: false], req_options)) do
      {:ok, %Req.Response{status: 200, body: "wardrik " <> ^nonce}} ->
        :ok

      {:ok, %Req.Response{status: status}} ->
        {:error, "#{target} answered #{status}, not this daemon"}

      {:error, reason} ->
        {:error, "#{target} did not answer: #{Exception.message(reason)}"}
    end
  end

  @doc "Where `listener` listens, or `:error` while it cannot."
  @spec listening(GenServer.server()) :: {:ok, {:inet.ip_address(), :inet.port_number()}} | :error
  def listening(listener \\ __MODULE__), do: GenServer.call(listener, :listening)

  @impl GenServer
  def init(opts) do
    # Bandit is linked to this process, and says why when it stops.
    Process.flag(:trap_exit, true)

    state = %{
      ip: Keyword.get(opts, :ip, ip()),
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
    Logger.warning("The OAuth callback stopped listening: #{inspect(reason)}")
    Process.send_after(self(), :listen, state.retry)
    {:noreply, %{state | server: nil}}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  defp listen(%{ip: ip, port: port} = state, attempt) do
    options = [plug: WardrikOAuth.Callback.Page, ip: ip, port: port, startup_log: false]

    case Bandit.start_link(options) do
      {:ok, server} ->
        if attempt == :again, do: Logger.info("The OAuth callback listens on #{port} now")
        %{state | server: server}

      {:error, reason} ->
        if attempt == :first do
          Logger.warning(
            "The OAuth callback could not listen on #{port}: #{inspect(reason)}. " <>
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

  @doc "What `check` answers for `params`: the nonce it was sent, back."
  @spec checked(map()) :: {pos_integer(), String.t()}
  def checked(%{"nonce" => nonce}) when is_binary(nonce) do
    if Regex.match?(@nonce, nonce), do: {200, "wardrik " <> nonce}, else: {400, "bad nonce"}
  end

  def checked(_params), do: {400, "no nonce"}

  defp tag(reason) when is_atom(reason), do: reason
  defp tag(reason) when is_tuple(reason), do: elem(reason, 0)
  defp tag(_reason), do: :failed
end
