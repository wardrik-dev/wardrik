defmodule WardrikHTTP.Plug do
  @moduledoc """
  Wardrik's HTTP API inside your Phoenix app. Mount it in your endpoint at
  a path, and it serves your instance's agents there, to each request as
  the user your instance's `c:Wardrik.authenticate/1` says it comes from:

      # lib/my_app_web/endpoint.ex, before Plug.Parsers
      plug WardrikHTTP.Plug, at: "/agents", agents: MyApp.Agents

      # config/runtime.exs
      config :my_app, MyApp.Agents,
        store: [repo: MyApp.Repo],
        plugins: [WardrikHTTP]

      # lib/my_app/agents.ex
      defmodule MyApp.Agents do
        use Wardrik, otp_app: :my_app

        @impl Wardrik
        def principal(%MyApp.Accounts.User{org: org, id: id}), do: %{org: org, id: id}

        @impl Wardrik
        def authenticate(conn) do
          with ["Bearer " <> token] <- Plug.Conn.get_req_header(conn, "authorization"),
               {:ok, user} <-
                 Phoenix.Token.verify(MyAppWeb.Endpoint, "agents", token, max_age: 86_400) do
            {:ok, user}
          else
            _no_session -> :error
          end
        end
      end

  Notice it goes before `Plug.Parsers`: a webhook's or Slack's signature is
  over the body as it was sent, so the body must reach it unread. It
  answers requests under `at` and passes every other one on to the rest of
  your endpoint.

  The user `authenticate/1` answers is the one you call your instance as:
  `c:Wardrik.principal/1` and `c:Wardrik.grants/1` decide what a request
  may do, as they decide what your own code may. A program reaches the API
  under `at`, as the TypeScript SDK does with
  `https://myapp.example.com/agents` as its base URL.

  It also serves what your plugins add there: the pages a sign-in comes
  back to, where `WardrikOAuth`'s redirect URL is under `at`, and what a
  chat channel's medium sends. `WardrikHTTP`, among your plugins, runs what
  the API needs.

  Your endpoint doesn't compile where the instance has no `authenticate/1`.

  ## Options

    * `:at` - the path it serves, as `"/agents"`. Required.
    * `:agents` - your `use Wardrik` instance. Required.
  """

  @behaviour Plug

  @impl Plug
  def init(opts) do
    opts = Keyword.validate!(opts, [:at, :agents])
    agents = Keyword.fetch!(opts, :agents)
    authenticator!(agents)
    {segments(Keyword.fetch!(opts, :at)), agents}
  end

  @impl Plug
  def call(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn, {at, agents}) do
    if List.starts_with?(conn.path_info, at) do
      rest = Enum.drop(conn.path_info, length(at))
      conn |> Plug.forward(rest, WardrikHTTP.Router, options(agents)) |> Plug.Conn.halt()
    else
      conn
    end
  end

  def call(%Plug.Conn{}, {at, agents}) do
    raise ArgumentError, """
    WardrikHTTP.Plug got a request whose body was already parsed, so it can't \
    check a signature over what was sent. Mount it in your endpoint, before \
    Plug.Parsers:

        plug WardrikHTTP.Plug, at: "/#{Enum.join(at, "/")}", agents: #{inspect(agents)}
    """
  end

  defp segments(at) when is_binary(at) do
    case String.split(at, "/", trim: true) do
      [] -> raise ArgumentError, ~s(WardrikHTTP.Plug's at: is the path it serves, as "/agents")
      segments -> segments
    end
  end

  defp options(agents) do
    host = Wardrik.Instance.host(agents)

    WardrikHTTP.Router.init(
      host: host,
      authenticator: %WardrikHTTP.Instance{agents: agents},
      workers: workers!(host, agents)
    )
  end

  @doc false
  def authenticator!(agents) do
    Code.ensure_compiled!(agents)

    unless function_exported?(agents, :authenticate, 1),
      do:
        raise(ArgumentError, """
        #{inspect(agents)} serves the HTTP API, so it says who each request comes from. Add:

            @impl Wardrik
            def authenticate(conn), do: {:ok, user} or :error
        """)

    %WardrikHTTP.Instance{agents: agents}
  end

  defp workers!(host, agents) do
    case Wardrik.Host.settings(host, WardrikHTTP) do
      [workers: workers] ->
        workers

      [] ->
        raise ArgumentError,
              "#{inspect(agents)} runs nothing the HTTP API needs: add WardrikHTTP to its plugins"
    end
  end
end
