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
  | `GET /v1/owners/{owner}/secrets` | lists secrets, never values |
  | `PUT`, `DELETE /v1/owners/{owner}/secrets/{name}` | seals or removes a secret |
  | `GET /v1/owners/{owner}/ceilings` | an org's spend against each ceiling |
  | `GET`, `POST /v1/owners/{owner}/servers`, `DELETE .../{name}` | MCP servers |
  | `GET`, `POST /v1/owners/{owner}/notify_targets`, `DELETE .../{name}` | webhooks |
  | `GET`, `POST /v1/owners/{owner}/providers`, `DELETE .../{name}` | OAuth apps |
  | `GET /v1/connections` | your accounts |
  | `POST`, `DELETE /v1/connections/{provider}` | starts a sign-in; forgets an account |
  | `POST /v1/connections/{provider}/pair` | finishes a browser sign-in with its code |
  | `GET`, `POST /v1/tokens`, `DELETE /v1/tokens/{id}` | tokens |
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

  Other options go to Bandit, such as `:port` and `:ip`.
  """

  use Plug.Router, copy_opts_to_assign: :daemon

  alias Wardrik.Error
  alias WardrikCore.Principal
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Ceiling
  alias WardrikDaemon.Connections
  alias WardrikDaemon.CreateAgent
  alias WardrikDaemon.NotifyTargets
  alias WardrikDaemon.OAuthApps
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Secrets
  alias WardrikDaemon.Servers
  alias WardrikDaemon.Tokens
  alias WardrikHTTP.Response
  alias WardrikVault.Secret

  @own [:wardrik, :authenticator, :store, :orgs, :config]
  @request_id Plug.RequestId.init(http_header: "request-id")
  @openapi_path Application.app_dir(:wardrik_daemon, "priv/openapi.json")
  @external_resource @openapi_path
  @openapi @openapi_path |> File.read!() |> JSON.decode!()
  @inputs Map.new(
            ~w(server_input notify_target_input provider_input token_input pairing_input),
            &{&1, JSV.build!(@openapi["components"]["schemas"][&1])}
          )

  @doc "Returns a child spec that serves with Bandit. Options not listed above go to Bandit."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    {own, bandit} = Keyword.split(opts, @own)
    Bandit.child_spec([plug: {__MODULE__, own}] ++ bandit)
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

      %{method: "put", path: "/v1/owners/{owner}/secrets/{name}"} =
        WardrikDaemon.HTTP.operation("secrets.put")
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
         :ok <- named(owner),
         :ok <- kept(owner, daemon.orgs) do
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

  get "/v1/owners/:owner/secrets" do
    served(conn, owner, {"secret.read", :secret}, fn _scope ->
      {:ok, 200, %{"secrets" => Secrets.list(conn.assigns.daemon.wardrik, owner)}}
    end)
  end

  put "/v1/owners/:owner/secrets/:name" do
    served(conn, owner, {"secret.put", :secret}, fn scope ->
      with {:ok, %{"value" => value, "purpose" => purpose}} <- sealing(conn) do
        secret = %Secret{principal: %Principal{id: owner}, name: name, value: value}
        opts = [purpose: purpose, actor: scope.principal]
        stored(Secrets.put(conn.assigns.daemon.wardrik, secret, opts))
      end
    end)
  end

  delete "/v1/owners/:owner/secrets/:name" do
    served(conn, owner, {"secret.put", :secret}, fn scope ->
      stored(Secrets.delete(conn.assigns.daemon.wardrik, {owner, name}, scope.principal))
    end)
  end

  get "/v1/owners/:owner/ceilings" do
    served(conn, owner, {"ceiling.read", :ceiling}, fn _scope -> ceilings(conn, owner) end)
  end

  get "/v1/owners/:owner/servers" do
    served(conn, owner, {"mcp_server.read", :mcp_server}, fn _scope ->
      {:ok, 200, %{"servers" => Servers.list(conn.assigns.daemon, owner)}}
    end)
  end

  post "/v1/owners/:owner/servers" do
    served(conn, owner, {"mcp_server.add", :mcp_server}, fn scope ->
      with {:ok, input} <- input(conn, "server_input"),
           {:ok, added} <- Servers.add(conn.assigns.daemon, {owner, input}, scope.principal),
           do: {:ok, 201, added}
    end)
  end

  delete "/v1/owners/:owner/servers/:name" do
    served(conn, owner, {"mcp_server.add", :mcp_server}, fn scope ->
      with {:ok, removed} <- Servers.remove(conn.assigns.daemon, {owner, name}, scope.principal),
           do: {:ok, 200, removed}
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
    served(conn, owner, {"notify_target.add", :notify_target}, fn scope ->
      with {:ok, removed} <-
             NotifyTargets.remove(conn.assigns.daemon, {owner, name}, scope.principal),
           do: {:ok, 200, removed}
    end)
  end

  get "/v1/owners/:owner/providers" do
    served(conn, owner, {"provider.read", :provider}, fn _scope ->
      {:ok, 200, %{"providers" => OAuthApps.list(conn.assigns.daemon, owner)}}
    end)
  end

  post "/v1/owners/:owner/providers" do
    served(conn, owner, {"provider.add", :provider}, fn scope ->
      with {:ok, input} <- input(conn, "provider_input"),
           {:ok, added} <- OAuthApps.add(conn.assigns.daemon, {owner, input}, scope.principal),
           do: {:ok, 201, added}
    end)
  end

  delete "/v1/owners/:owner/providers/:name" do
    served(conn, owner, {"provider.add", :provider}, fn scope ->
      with {:ok, removed} <- OAuthApps.remove(conn.assigns.daemon, {owner, name}, scope.principal),
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
    served(conn, {"connection.connect", &own_connections/1}, fn scope ->
      with {:ok, connection} <-
             Connections.disconnect(conn.assigns.daemon, scope.principal, provider),
           do: {:ok, 200, connection}
    end)
  end

  get "/v1/tokens" do
    served(conn, {"token.read", {:token, "*"}}, fn _scope ->
      {:ok, 200, %{"tokens" => Enum.map(Tokens.list(conn.assigns.daemon.store), &token/1)}}
    end)
  end

  # The subject is checked as the resource, so a rule's names can say whom a token may act as.
  post "/v1/tokens" do
    conn = Plug.RequestId.call(conn, @request_id)

    with {:ok, scope} <- authenticated(conn, conn.assigns.daemon),
         {:ok, input} <- input(conn, "token_input"),
         :ok <- authorized(scope, "token.create", {:token, input["subject"]}),
         {:ok, created} <- created(conn.assigns.daemon.store, input) do
      answer(conn, 201, created)
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  delete "/v1/tokens/:id" do
    served(conn, {"token.revoke", {:token, id}}, fn _scope ->
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
        <p>To finish signing in to #{escape(provider)}, enter this code where you ran
        <code>wardrik connection connect</code>:</p>
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
         :ok <- authorized(scope, action, resource(resource, scope)),
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
         :ok <- named(owner),
         :ok <- authorized(scope, action, {kind, owner}),
         :ok <- kept(owner, daemon.orgs),
         {:ok, status, body} <- run.(scope) do
      answer(conn, status, body)
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

  defp authenticated(conn, %{wardrik: wardrik, authenticator: {module, opts}}) do
    request = %WardrikHTTP.Authenticator.Request{conn: conn, server: Wardrik, wardrik: wardrik}
    module.authenticate(request, opts)
  end

  defp named(owner) do
    if Owners.valid?(owner),
      do: :ok,
      else:
        {:error,
         Error.new(
           :invalid_request,
           "#{owner} isn't an owner: give an org, an org/@person or deployment."
         )}
  end

  defp kept("deployment", _orgs), do: :ok
  defp kept(owner, orgs), do: WardrikDaemon.Orgs.known(Owners.org(owner), orgs)

  defp authorized(scope, action, resource) do
    case Wardrik.Authorizer.authorize(scope, action: action, resource: resource) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "There's no #{described(resource)}.")}

      {:error, :forbidden} ->
        {:error, Error.new(:forbidden, "You may not do this to the #{described(resource)}.")}
    end
  end

  defp described({:agents, owner}), do: "agents of #{owner}"
  defp described({:secret, owner}), do: "secrets of #{owner}"
  defp described({:ceiling, owner}), do: "ceilings of #{owner}"
  defp described({:mcp_server, owner}), do: "MCP servers of #{owner}"
  defp described({:notify_target, owner}), do: "notify targets of #{owner}"
  defp described({:provider, owner}), do: "OAuth apps of #{owner}"
  defp described({:connection, id}), do: "connections of #{id}"
  defp described({:token, _id}), do: "token"

  defp input(conn, schema) do
    with {:ok, input} <- json(conn),
         {:ok, input} <- JSV.validate(input, Map.fetch!(@inputs, schema)) do
      {:ok, input}
    else
      {:error, %JSV.ValidationError{} = error} ->
        {:error, Error.new(:invalid_request, Exception.message(error))}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp json(conn) do
    with {:ok, body, _conn} <- Plug.Conn.read_body(conn),
         {:ok, input} <- JSON.decode(body) do
      {:ok, input}
    else
      _unread -> {:error, Error.new(:invalid_request, "Send the body as JSON.")}
    end
  end

  @expires_in 30 * 24 * 3600

  defp created(store, input) do
    expires = DateTime.add(DateTime.utc_now(), Map.get(input, "expires_in", @expires_in), :second)

    opts = [
      name: input["name"],
      subject: input["subject"],
      groups: Map.get(input, "groups", []),
      expires: expires
    ]

    case Tokens.create(store, opts) do
      {:ok, %{token: created, secret: secret}} -> {:ok, Map.put(token(created), "secret", secret)}
      {:error, error} -> {:error, Error.new(:invalid_request, Exception.message(error))}
    end
  end

  defp token(token) do
    %{
      "id" => token.id,
      "name" => token.name,
      "subject" => token.subject,
      "groups" => token.groups,
      "expires" => DateTime.to_iso8601(token.expires)
    }
  end

  defp sealing(conn) do
    with {:ok, body, _conn} <- Plug.Conn.read_body(conn),
         {:ok, %{} = input} <- JSON.decode(body),
         :ok <- sealable(input) do
      {:ok, input}
    else
      {:error, %Error{} = error} -> {:error, error}
      _unread -> {:error, unsealable()}
    end
  end

  defp sealable(%{"value" => value, "purpose" => purpose} = input)
       when is_binary(value) and value != "" and map_size(input) == 2 do
    if purpose in Secrets.purposes(), do: :ok, else: {:error, unsealable()}
  end

  defp sealable(_input), do: {:error, unsealable()}

  defp unsealable do
    purposes = Enum.join(Enum.sort(Secrets.purposes()), ", ")

    Error.new(
      :invalid_request,
      ~s(Send {"value": ..., "purpose": ...}, with a value and a purpose of #{purposes}.)
    )
  end

  defp stored(:ok), do: {:ok, 204, nil}

  defp stored({:error, reason}),
    do: {:error, Error.new(:unavailable, "The vault didn't keep it: #{inspect(reason)}.")}

  defp ceilings(conn, owner) do
    %{store: store, orgs: orgs} = conn.assigns.daemon
    org = Owners.org(owner)

    with :ok <- an_org(owner, org),
         {:ok, settings} <- WardrikDaemon.Orgs.settings(org, orgs) do
      spent = for ceiling <- settings.ceilings, do: Ceiling.json(store, org, ceiling)
      {:ok, 200, %{"ceilings" => Enum.sort_by(spent, & &1["ceiling"])}}
    end
  end

  defp an_org(org, org), do: :ok

  defp an_org(_owner, org),
    do: {:error, Error.new(:invalid_request, "Ceilings are an org's: ask for #{org}'s.")}

  defp record(record),
    do: %{"id" => record.id, "name" => record.name, "org" => record.org, "owner" => record.owner}

  defp answer(conn, status, nil), do: Plug.Conn.send_resp(conn, status, "")
  defp answer(conn, status, body), do: Response.json(conn, status, body)
end
