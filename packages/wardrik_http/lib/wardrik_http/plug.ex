defmodule WardrikHTTP.Plug do
  @moduledoc """
  Wardrik's HTTP API inside your Phoenix app. Forward a path to it, and it
  serves your instance's agents there, to each request as the user your
  instance's `c:Wardrik.authenticate/1` says it comes from:

      # lib/my_app_web/router.ex
      forward "/agents", WardrikHTTP.Plug, agents: MyApp.Agents

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

  Notice the user `authenticate/1` answers is the one you call your
  instance as: `c:Wardrik.principal/1` and `c:Wardrik.grants/1` decide what
  a request may do, as they decide what your own code may. A program
  reaches the API under the path you forwarded, as the TypeScript SDK does
  with `https://myapp.example.com/agents` as its base URL.

  It also serves what your plugins add there: the pages a sign-in comes
  back to, where `WardrikOAuth`'s redirect URL is under the path, and what
  a chat channel's medium sends. `WardrikHTTP`, among your plugins, runs
  what the API needs.

  Your router doesn't compile where the instance has no `authenticate/1`.
  """

  @behaviour Plug

  @impl Plug
  def init(opts) do
    agents = opts |> Keyword.validate!([:agents]) |> Keyword.fetch!(:agents)
    authenticator!(agents)
    agents
  end

  @impl Plug
  def call(conn, agents) do
    host = Wardrik.Instance.host(agents)

    options = [
      host: host,
      authenticator: %WardrikHTTP.Instance{agents: agents},
      workers: workers!(host, agents)
    ]

    WardrikHTTP.Router.call(conn, WardrikHTTP.Router.init(options))
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
