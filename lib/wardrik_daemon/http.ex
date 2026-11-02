defmodule WardrikDaemon.HTTP do
  @moduledoc """
  The daemon's HTTP API: its own routes, with every other request served by `Wardrik.HTTP`.

  | Route | Serves |
  | --- | --- |
  | `GET /v1/owners/{owner}/secrets` | the owner's secrets, by name and purpose, never a value |
  | `PUT /v1/owners/{owner}/secrets/{name}` | seals a secret. See `WardrikDaemon.Secrets`. |
  | `DELETE /v1/owners/{owner}/secrets/{name}` | removes one |
  | `GET /v1/owners/{owner}/ceilings` | what an org has spent against each ceiling |
  | `GET /v1/owners/{owner}/servers` | the MCP servers the owner's agents reach. See `WardrikDaemon.Servers`. |
  | `POST /v1/owners/{owner}/servers` | adds one, started on every node |
  | `DELETE /v1/owners/{owner}/servers/{name}` | removes one of the owner's own |
  | `GET /v1/owners/{owner}/notify_targets` | the webhooks the owner's agents' notices reach. See `WardrikDaemon.NotifyTargets`. |
  | `POST /v1/owners/{owner}/notify_targets` | adds one |
  | `DELETE /v1/owners/{owner}/notify_targets/{name}` | removes one of the owner's own |
  | `GET /v1/tokens` | every token, never a secret. See `WardrikDaemon.Tokens`. |
  | `POST /v1/tokens` | creates one, answering its secret once |
  | `DELETE /v1/tokens/{id}` | revokes one |

  `priv/openapi.json` describes them, as `openapi/0` returns it.

  An owner is one path segment, encoded: `acme`, `acme%2F%40jon` or `deployment`.

  Its routes take the same tokens (`WardrikDaemon.Authenticator`), and are decided by the same
  roles and bindings (`WardrikDaemon.Authorizer`), on `{:secret, owner}`, `{:ceiling, org}`,
  `{:mcp_server, owner}`, `{:notify_target, owner}` and `{:token, id}`. A body is checked against
  its schema in `priv/openapi.json`. They answer errors as `Wardrik.HTTP` does.

      {WardrikDaemon.HTTP,
       wardrik: name,
       authenticator: {WardrikDaemon.Authenticator, store},
       store: store,
       orgs: orgs,
       config: config,
       port: 4747}

  ## Options

    * `:wardrik` - required. The Wardrik it serves.
    * `:authenticator` - required. As `Wardrik.HTTP` takes it.
    * `:store` - required. The daemon's scope of the store, where it keeps tokens, servers,
      notify targets and ceilings' spend.
    * `:orgs` - required. What `WardrikDaemon.Orgs` reads orgs from. An owner in an org it doesn't
      run is answered as one that isn't there.
    * `:config` - required. `config.yaml`, as `WardrikDaemon.Config.read/3` returns it.

  As a child, it also takes Bandit's options, such as `:port` and `:ip`.
  """

  use Plug.Router, copy_opts_to_assign: :daemon

  alias Wardrik.Error
  alias WardrikCore.Principal
  alias WardrikDaemon.Ceiling
  alias WardrikDaemon.NotifyTargets
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
            ~w(server_input notify_target_input token_input),
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
                   for %{"$ref" => "#/components/parameters/" <> name} <- operation["parameters"],
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
  Returns the daemon's own operation `id`, as `WardrikProtocol.operation/1` returns Wardrik's, with
  its `:method`, `:path` and `:parameters`. Returns `nil` if the daemon has none of that ID.

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

  match _ do
    Wardrik.HTTP.call(conn, conn.assigns.daemon.http)
  end

  # Who asks is checked first, so a route answers 401 to anyone without a token, whatever they
  # ask for.
  defp served(conn, {action, resource}, run) do
    conn = Plug.RequestId.call(conn, @request_id)

    with {:ok, scope} <- authenticated(conn, conn.assigns.daemon),
         :ok <- authorized(scope, action, resource),
         {:ok, status, body} <- run.(scope) do
      answer(conn, status, body)
    else
      {:error, %Error{} = error} -> Response.error(conn, error)
    end
  end

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

  defp described({:secret, owner}), do: "secrets of #{owner}"
  defp described({:ceiling, owner}), do: "ceilings of #{owner}"
  defp described({:mcp_server, owner}), do: "MCP servers of #{owner}"
  defp described({:notify_target, owner}), do: "notify targets of #{owner}"
  defp described({:token, _id}), do: "token"

  defp input(conn, schema) do
    with {:ok, body, _conn} <- Plug.Conn.read_body(conn),
         {:ok, input} <- JSON.decode(body),
         {:ok, input} <- JSV.validate(input, Map.fetch!(@inputs, schema)) do
      {:ok, input}
    else
      {:error, %JSV.ValidationError{} = error} ->
        {:error, Error.new(:invalid_request, Exception.message(error))}

      _unread ->
        {:error, Error.new(:invalid_request, "Send the body as JSON.")}
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

  defp answer(conn, status, nil), do: Plug.Conn.send_resp(conn, status, "")
  defp answer(conn, status, body), do: Response.json(conn, status, body)
end
