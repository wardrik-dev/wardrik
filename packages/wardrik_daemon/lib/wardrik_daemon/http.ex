defmodule WardrikDaemon.HTTP do
  @moduledoc """
  The daemon's HTTP API. It serves its own routes, and passes every other request to `Wardrik.HTTP`.

      {WardrikDaemon.HTTP,
       wardrik: name,
       authenticator: {WardrikDaemon.Authenticator, store},
       store: store,
       orgs: orgs,
       config: config,
       port: 4747}

  | Route | Does |
  | --- | --- |
  | `GET`, `POST /v1/owners/{owner}/agents` | finds agents by `?name=`; makes one |
  | `GET /v1/owners/{owner}/ceilings` | an org's spend against each ceiling |
  | `POST /v1/connections/{provider}/pair` | finishes a browser sign-in with its code |
  | `GET`, `POST /v1/tokens`, `DELETE /v1/tokens/{id}` | tokens |
  | `POST /v1/tokens/web` | a sign-in link for the dashboard |
  | `POST /mcp` | Wardrik's operations and these, as MCP tools; see `Wardrik.HTTP.MCP` |
  | `/web` | the dashboard; see `WardrikDaemon.Web` |
  | `GET /oauth/callback` | shows the code that finishes a browser sign-in |

    * `priv/openapi.json` describes them. `WardrikDaemon.Operations` runs them.
    * `{owner}` is `acme`, `acme%2F%40jon` (a person) or `deployment`.
    * Tokens and permissions work as for Wardrik's routes. See `WardrikDaemon.Authenticator` and
      `WardrikDaemon.Authorizer`.

  ## Options

    * `:wardrik` - required. The Wardrik it serves.
    * `:authenticator` - required. As `Wardrik.HTTP` takes it.
    * `:store` - required. The daemon's scope of the store.
    * `:orgs` - required. Where `WardrikDaemon.Orgs` reads orgs from.
    * `:config` - required. The `WardrikDaemon.Config`.
    * `:web` - the dashboard's secret key base, or `nil` while it's off. See `WardrikDaemon.Web`.
    * `:retry` - milliseconds between tries for a port another node on this machine holds, as
      `WardrikDaemon.Listener` takes it. Without it, a port that's taken fails the start.

  Other options go to Bandit, such as `:port` and `:ip`.
  """

  use Plug.Router, copy_opts_to_assign: :daemon

  alias Wardrik.Error
  alias Wardrik.HTTP.MCP
  alias Wardrik.HTTP.Response
  alias WardrikDaemon.Connections
  alias WardrikDaemon.Operations

  @own [:wardrik, :authenticator, :store, :orgs, :config, :web]
  @request_id Plug.RequestId.init(http_header: "request-id")
  @openapi_path Application.app_dir(:wardrik_daemon, "priv/openapi.json")
  @external_resource @openapi_path
  @openapi @openapi_path
           |> File.read!()
           |> JSON.decode!()
  @inputs Map.new(
            ~w(token_input pairing_input web_input),
            &{&1, JSV.build!(@openapi["components"]["schemas"][&1])}
          )

  @doc "Returns a child spec that serves with Bandit. Options not listed above go to Bandit."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    {retry, opts} = Keyword.pop(opts, :retry)
    {own, bandit} = Keyword.split(opts, @own)
    bandit = [plug: {__MODULE__, own}] ++ bandit

    if retry,
      do: WardrikDaemon.Listener.child_spec(bandit: bandit, retry: retry),
      else: Bandit.child_spec(bandit)
  end

  @doc "Returns the daemon's own routes, as OpenAPI."
  @spec openapi() :: map()
  def openapi, do: @openapi

  @doc """
  Returns the daemon's operation `id`, with its `:method`, `:path` and `:parameters`, or `nil`.

      %{method: "post", path: "/v1/tokens"} =
        WardrikDaemon.HTTP.operation("tokens.create")
  """
  @spec operation(String.t()) :: Operations.operation() | nil
  def operation(id), do: Operations.get(id)

  @doc "Returns the daemon's own routes, as `{method, path}` in OpenAPI's form."
  @spec routes() :: [{String.t(), String.t()}]
  def routes,
    do: for(%{method: method, path: path} <- Operations.list(), do: {method, path})

  @impl Plug
  def init(opts) do
    {wardrik, authenticator} =
      {Keyword.fetch!(opts, :wardrik), Keyword.fetch!(opts, :authenticator)}

    %{
      wardrik: wardrik,
      authenticator: authenticator,
      store: Keyword.fetch!(opts, :store),
      orgs: Keyword.fetch!(opts, :orgs),
      config: Keyword.fetch!(opts, :config),
      web: Keyword.get(opts, :web),
      http: Wardrik.HTTP.init(wardrik: wardrik, authenticator: authenticator)
    }
  end

  plug :match
  plug :dispatch

  get "/v1/owners/:owner/agents" do
    run_operation(conn, "agents.find", %{"owner" => owner})
  end

  post "/v1/owners/:owner/agents" do
    run_operation(conn, "agents.create", %{"owner" => owner})
  end

  get "/v1/owners/:owner/ceilings" do
    run_operation(conn, "ceilings.list", %{"owner" => owner})
  end

  post "/v1/connections/:provider/pair" do
    run_operation(conn, "connections.pair", %{"provider" => provider})
  end

  get "/v1/tokens" do
    run_operation(conn, "tokens.list", %{})
  end

  post "/v1/tokens" do
    run_operation(conn, "tokens.create", %{})
  end

  post "/v1/tokens/web" do
    run_operation(conn, "tokens.web", %{})
  end

  delete "/v1/tokens/:id" do
    run_operation(conn, "tokens.revoke", %{"id" => id})
  end

  # Wardrik's operations and the daemon's, as tools.
  match "/mcp" do
    conn = Plug.RequestId.call(conn, @request_id)
    daemon = conn.assigns.daemon

    case authenticate(conn, daemon) do
      {:ok, scope} ->
        own =
          daemon
          |> Operations.new(scope)
          |> Operations.build_tools()

        MCP.serve(conn, MCP.build_tools(scope) ++ own)

      {:error, %Error{} = error} ->
        Response.error(conn, error)
    end
  end

  # The page can't tell who is at the browser, so it finishes nothing. See WardrikDaemon.Pairings.
  get "/oauth/callback" do
    conn = Plug.Conn.fetch_query_params(conn)

    case Connections.take_callback(conn.assigns.daemon, conn.query_params) do
      {:ok, %{provider: provider, code: code}} ->
        page(conn, 200, "Enter this code", """
        <p>To finish signing in to #{escape(provider)}, enter this code on the Connections page of
        the dashboard, or where you ran <code>wardrik connection connect</code>:</p>
        <p class="code">#{code}</p>
        <p>It works once, for 10 minutes. If you didn't start this sign-in, close this page.</p>
        """)

      {:error, :declined} ->
        page(conn, 400, "Sign-in didn't finish", "<p>The sign-in was declined.</p>")

      {:error, :unknown} ->
        page(conn, 404, "Sign-in not found", """
        <p>This sign-in has ended, or wasn't started here. Run
        <code>wardrik connection connect</code> again.</p>
        """)
    end
  end

  # The dashboard's pages, assets and socket. When the dashboard is off, /web returns not_found.
  match "/web/*_rest" do
    case conn.assigns.daemon.web do
      nil -> Wardrik.HTTP.call(conn, conn.assigns.daemon.http)
      _key -> WardrikDaemon.Web.Endpoint.call(conn, WardrikDaemon.Web.Endpoint.init([]))
    end
  end

  match _ do
    Wardrik.HTTP.call(conn, conn.assigns.daemon.http)
  end

  defp page(conn, status, title, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.put_resp_header("referrer-policy", "no-referrer")
    |> Plug.Conn.send_resp(status, """
    <!doctype html>
    <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <title>#{title}</title>
    <style>body{font:16px system-ui;max-width:32rem;margin:4rem auto;padding:0 1rem}.code{font:2rem monospace;letter-spacing:.2rem}</style>
    </head><body><h1>#{title}</h1>#{body}</body></html>
    """)
  end

  defp escape(text) do
    text
    |> Plug.HTML.html_escape()
    |> IO.iodata_to_binary()
  end

  # Who asks is checked first, so a route answers 401 to anyone without a token, whatever they
  # ask for.
  defp run_operation(conn, id, params) do
    conn =
      conn
      |> Plug.RequestId.call(@request_id)
      |> Plug.Conn.fetch_query_params()

    daemon = conn.assigns.daemon
    operation = Operations.get(id)

    with {:ok, scope} <- authenticate(conn, daemon),
         {:ok, body} <- read_body_input(conn, operation.body),
         input = Map.merge(body, Map.merge(read_query_input(conn, operation), params)),
         operations = Operations.new(daemon, scope),
         {:ok, output} <- Operations.run(operations, id, input) do
      send_output(conn, operation.status, output)
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  defp read_query_input(conn, %{parameters: parameters}),
    do:
      for(
        %{in: "query", name: name} <- parameters,
        Map.has_key?(conn.query_params, name),
        into: %{},
        do: {name, conn.query_params[name]}
      )

  defp read_body_input(_conn, :none), do: {:ok, %{}}

  defp read_body_input(conn, :required) do
    with {:ok, body, _conn} <- Plug.Conn.read_body(conn),
         {:ok, %{} = input} <- JSON.decode(body) do
      {:ok, input}
    else
      _unread -> {:error, Error.new(:invalid_request, "Send the body as JSON.")}
    end
  end

  # A body that may be left out, as nothing or as {}.
  defp read_body_input(conn, :optional) do
    case Plug.Conn.read_body(conn) do
      {:ok, "", _conn} -> {:ok, %{}}
      {:ok, _body, _conn} = read -> decode_body(read)
    end
  end

  defp decode_body({:ok, body, _conn}) do
    case JSON.decode(body) do
      {:ok, %{} = input} -> {:ok, input}
      _unread -> {:error, Error.new(:invalid_request, "Send the body as JSON.")}
    end
  end

  defp authenticate(conn, %{wardrik: wardrik, authenticator: {module, opts}}) do
    request = %Wardrik.HTTP.Authenticator.Request{conn: conn, server: Wardrik, wardrik: wardrik}
    module.authenticate(request, opts)
  end

  @doc "Validates `input` against one of the daemon's input schemas, for example `server_input`."
  @spec validate_input(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def validate_input(schema, input) do
    case JSV.validate(input, Map.fetch!(@inputs, schema)) do
      {:ok, input} -> {:ok, input}
      {:error, error} -> {:error, Error.new(:invalid_request, Exception.message(error))}
    end
  end

  @doc "Returns one of the daemon's input schemas as JSON Schema, for example `server_input`."
  @spec schema(String.t()) :: map()
  def schema(name), do: Map.fetch!(@openapi["components"]["schemas"], name)

  defp send_output(conn, status, nil), do: Plug.Conn.send_resp(conn, status, "")
  defp send_output(conn, status, body), do: Response.json(conn, status, body)
end
