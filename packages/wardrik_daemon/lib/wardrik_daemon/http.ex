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
  | `GET`, `POST /v1/owners/{owner}/notify_targets`, `DELETE .../{name}` | webhooks |
  | `GET /v1/connections` | your accounts |
  | `POST`, `DELETE /v1/connections/{provider}` | starts a sign-in; forgets an account |
  | `POST /v1/connections/{provider}/pair` | finishes a browser sign-in with its code |
  | `GET`, `POST /v1/tokens`, `DELETE /v1/tokens/{id}` | tokens |
  | `POST /v1/tokens/web` | a sign-in link for the dashboard |
  | `/web` | the dashboard; see `WardrikDaemon.Web` |
  | `GET /oauth/callback` | shows the code that finishes a browser sign-in |

    * `priv/openapi.json` describes them. Bodies are checked against it.
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
  alias Wardrik.HTTP.Response
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Ceiling
  alias WardrikDaemon.Connections
  alias WardrikDaemon.CreateAgent
  alias WardrikDaemon.NotifyTargets
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Tokens

  @own [:wardrik, :authenticator, :store, :orgs, :config, :web]
  @request_id Plug.RequestId.init(http_header: "request-id")
  @openapi_path Application.app_dir(:wardrik_daemon, "priv/openapi.json")
  @external_resource @openapi_path
  @openapi @openapi_path |> File.read!() |> JSON.decode!()
  @inputs Map.new(
            ~w(notify_target_input token_input pairing_input),
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

  @operations (for {path, methods} <- @openapi["paths"],
                   {method, operation} <- methods,
                   into: %{} do
                 parameters =
                   for %{"$ref" => "#/components/parameters/" <> name} <-
                         Map.get(operation, "parameters", []),
                       parameter = @openapi["components"]["parameters"][name],
                       do: %{name: parameter["name"], in: parameter["in"]}

                 {operation["operationId"],
                  %{
                    id: operation["operationId"],
                    method: method,
                    path: path,
                    parameters: parameters
                  }}
               end)

  @doc """
  Returns the daemon's operation `id`, with its `:method`, `:path` and `:parameters`, or `nil`.

      %{method: "post", path: "/v1/owners/{owner}/notify_targets"} =
        WardrikDaemon.HTTP.operation("notify_targets.add")
  """
  @spec operation(String.t()) :: map() | nil
  def operation(id), do: Map.get(@operations, id)

  @doc "Returns the daemon's own routes, as `{method, path}` in OpenAPI's form."
  @spec routes() :: [{String.t(), String.t()}]
  def routes,
    do: for(%{method: method, path: path} <- Map.values(@operations), do: {method, path})

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

  # Each agent is listed only where the caller may read it, so they learn of no other.
  get "/v1/owners/:owner/agents" do
    conn = conn |> Plug.RequestId.call(@request_id) |> Plug.Conn.fetch_query_params()
    daemon = conn.assigns.daemon

    with {:ok, scope} <- authenticated(conn, daemon),
         :ok <- Allowed.named(owner),
         :ok <- Allowed.kept(owner, daemon.orgs) do
      agents =
        for record <- AgentRecords.in_org(daemon.store, Owners.org(owner)),
            conn.query_params["name"] in [nil, record.name],
            match?({:ok, _read}, Wardrik.run(scope, "agent.read", %{"agent" => record.id})),
            do: record(record)

      answer(conn, 200, %{"agents" => agents})
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  post "/v1/owners/:owner/agents" do
    served(conn, owner, {"agent.create", :agents}, fn scope ->
      with {:ok, input} <- json(conn),
           {:ok, record} <- CreateAgent.create(conn.assigns.daemon, scope, {owner, input}),
           do: {:ok, 201, record(record)}
    end)
  end

  get "/v1/owners/:owner/ceilings" do
    served(conn, owner, {"ceiling.read", :ceiling}, fn _scope ->
      with {:ok, ceilings} <- Ceiling.list(conn.assigns.daemon, owner),
           do: {:ok, 200, %{"ceilings" => ceilings}}
    end)
  end

  get "/v1/owners/:owner/notify_targets" do
    served(conn, owner, {"notify_target.read", :notify_target}, fn _scope ->
      {:ok, 200, %{"targets" => NotifyTargets.list(conn.assigns.daemon, owner)}}
    end)
  end

  post "/v1/owners/:owner/notify_targets" do
    served(conn, owner, {"notify_target.add", :notify_target}, fn scope ->
      with {:ok, input} <- input(conn, "notify_target_input"),
           {:ok, added} <- NotifyTargets.add(conn.assigns.daemon, {owner, input}, scope.principal),
           do: {:ok, 201, added}
    end)
  end

  delete "/v1/owners/:owner/notify_targets/:name" do
    served(conn, owner, {"notify_target.delete", :notify_target}, fn scope ->
      with {:ok, removed} <-
             NotifyTargets.remove(conn.assigns.daemon, {owner, name}, scope.principal),
           do: {:ok, 200, removed}
    end)
  end

  get "/v1/connections" do
    served(conn, {"connection.read", &own_connections/1}, fn scope ->
      {:ok, 200, %{"connections" => Connections.list(conn.assigns.daemon, scope.principal)}}
    end)
  end

  post "/v1/connections/:provider" do
    served(conn, {"connection.connect", &own_connections/1}, fn scope ->
      with {:ok, connecting} <-
             Connections.connect(conn.assigns.daemon, scope.principal, provider),
           do: {:ok, 200, connecting}
    end)
  end

  post "/v1/connections/:provider/pair" do
    served(conn, {"connection.connect", &own_connections/1}, fn scope ->
      with {:ok, %{"code" => code}} <- input(conn, "pairing_input"),
           {:ok, connection} <-
             Connections.pair(conn.assigns.daemon, scope.principal, {provider, code}),
           do: {:ok, 200, connection}
    end)
  end

  delete "/v1/connections/:provider" do
    served(conn, {"connection.delete", &own_connections/1}, fn scope ->
      with :ok <- Connections.disconnect(conn.assigns.daemon, scope.principal, provider),
           do: {:ok, 204, nil}
    end)
  end

  get "/v1/tokens" do
    served(conn, {"token.read", {:token, "*"}}, fn _scope ->
      {:ok, 200, %{"tokens" => Enum.map(Tokens.list(conn.assigns.daemon.store), &Tokens.json/1)}}
    end)
  end

  # The subject is checked as the resource, so a rule's names can say whom a token may act as.
  post "/v1/tokens" do
    conn = Plug.RequestId.call(conn, @request_id)

    with {:ok, scope} <- authenticated(conn, conn.assigns.daemon),
         {:ok, input} <- input(conn, "token_input"),
         :ok <- Allowed.authorized(scope, "token.create", {:token, input["subject"]}),
         {:ok, created} <- Tokens.issue(conn.assigns.daemon.store, input) do
      answer(conn, 201, created)
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  post "/v1/tokens/web" do
    conn = Plug.RequestId.call(conn, @request_id)
    daemon = conn.assigns.daemon

    with {:ok, scope} <- authenticated(conn, daemon),
         {:ok, url} <- WardrikDaemon.Web.sign_in(daemon, scope) do
      answer(conn, 201, %{"url" => url})
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  delete "/v1/tokens/:id" do
    served(conn, {"token.delete", {:token, id}}, fn _scope ->
      :ok = Tokens.revoke(conn.assigns.daemon.store, id)
      {:ok, 204, nil}
    end)
  end

  # The page can't tell who is at the browser, so it finishes nothing. See WardrikDaemon.Pairings.
  get "/oauth/callback" do
    conn = Plug.Conn.fetch_query_params(conn)

    case Connections.called_back(conn.assigns.daemon, conn.query_params) do
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

  defp escape(text), do: text |> Plug.HTML.html_escape() |> IO.iodata_to_binary()

  # Who asks is checked first, so a route answers 401 to anyone without a token, whatever they
  # ask for.
  defp served(conn, {action, resource}, run) do
    conn = Plug.RequestId.call(conn, @request_id)

    with {:ok, scope} <- authenticated(conn, conn.assigns.daemon),
         :ok <- Allowed.authorized(scope, action, resource(resource, scope)),
         {:ok, status, body} <- run.(scope) do
      answer(conn, status, body)
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  # A caller's connections are their own, as the principal their token acts as.
  defp own_connections(scope), do: {:connection, scope.principal.id}

  defp resource(resource, scope) when is_function(resource, 1), do: resource.(scope)
  defp resource(resource, _scope), do: resource

  defp served(conn, owner, {action, kind}, run) do
    conn = Plug.RequestId.call(conn, @request_id)
    daemon = conn.assigns.daemon

    with {:ok, scope} <- authenticated(conn, daemon),
         :ok <- Allowed.owned(daemon, scope, owner, {action, kind}),
         {:ok, status, body} <- run.(scope) do
      answer(conn, status, body)
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  defp authenticated(conn, %{wardrik: wardrik, authenticator: {module, opts}}) do
    request = %Wardrik.HTTP.Authenticator.Request{conn: conn, server: Wardrik, wardrik: wardrik}
    module.authenticate(request, opts)
  end

  defp input(conn, schema) do
    with {:ok, input} <- json(conn), do: checked(schema, input)
  end

  @doc "Validates `input` against one of the daemon's input schemas, for example `server_input`."
  @spec checked(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def checked(schema, input) do
    case JSV.validate(input, Map.fetch!(@inputs, schema)) do
      {:ok, input} -> {:ok, input}
      {:error, error} -> {:error, Error.new(:invalid_request, Exception.message(error))}
    end
  end

  @doc "Returns one of the daemon's input schemas as JSON Schema, for example `server_input`."
  @spec schema(String.t()) :: map()
  def schema(name), do: Map.fetch!(@openapi["components"]["schemas"], name)

  defp json(conn) do
    with {:ok, body, _conn} <- Plug.Conn.read_body(conn),
         {:ok, input} <- JSON.decode(body) do
      {:ok, input}
    else
      _unread -> {:error, Error.new(:invalid_request, "Send the body as JSON.")}
    end
  end

  defp record(record),
    do: %{"id" => record.id, "name" => record.name, "org" => record.org, "owner" => record.owner}

  defp answer(conn, status, nil), do: Plug.Conn.send_resp(conn, status, "")
  defp answer(conn, status, body), do: Response.json(conn, status, body)
end
