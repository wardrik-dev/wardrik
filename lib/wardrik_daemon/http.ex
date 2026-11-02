defmodule WardrikDaemon.HTTP do
  @moduledoc """
  The daemon's HTTP API: its own routes, with every other request served by `Wardrik.HTTP`.

  | Route | Serves |
  | --- | --- |
  | `GET /v1/owners/{owner}/secrets` | the owner's secrets, by name and purpose, never a value |
  | `PUT /v1/owners/{owner}/secrets/{name}` | seals a secret. See `WardrikDaemon.Secrets`. |
  | `DELETE /v1/owners/{owner}/secrets/{name}` | removes one |
  | `GET /v1/owners/{owner}/ceilings` | what an org has spent against each ceiling |

  `priv/openapi.json` describes them, as `openapi/0` returns it.

  An owner is one path segment, encoded: `acme`, `acme%2F%40jon` or `deployment`.

  Its routes take the same tokens (`WardrikDaemon.Authenticator`), and are decided by the same
  roles and bindings (`WardrikDaemon.Authorizer`), on `{:secret, owner}` and `{:ceiling, org}`.
  They answer errors as `Wardrik.HTTP` does.

      {WardrikDaemon.HTTP,
       wardrik: name,
       authenticator: {WardrikDaemon.Authenticator, store},
       store: store,
       orgs: orgs,
       port: 4747}

  ## Options

    * `:wardrik` - required. The Wardrik it serves.
    * `:authenticator` - required. As `Wardrik.HTTP` takes it.
    * `:store` - required. The daemon's scope of the store, where ceilings' spend is kept.
    * `:orgs` - required. What `WardrikDaemon.Orgs` reads orgs from. An owner in an org it doesn't
      run is answered as one that isn't there.

  As a child, it also takes Bandit's options, such as `:port` and `:ip`.
  """

  use Plug.Router, copy_opts_to_assign: :daemon

  alias Wardrik.Error
  alias WardrikCore.Principal
  alias WardrikDaemon.Ceiling
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Secrets
  alias WardrikHTTP.Response
  alias WardrikVault.Secret

  @own [:wardrik, :authenticator, :store, :orgs]
  @request_id Plug.RequestId.init(http_header: "request-id")
  @openapi_path Application.app_dir(:wardrik_daemon, "priv/openapi.json")
  @external_resource @openapi_path
  @openapi @openapi_path |> File.read!() |> JSON.decode!()

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
  def routes do
    [
      {"get", "/v1/owners/{owner}/secrets"},
      {"put", "/v1/owners/{owner}/secrets/{name}"},
      {"delete", "/v1/owners/{owner}/secrets/{name}"},
      {"get", "/v1/owners/{owner}/ceilings"}
    ]
  end

  @impl Plug
  def init(opts) do
    {wardrik, authenticator} =
      {Keyword.fetch!(opts, :wardrik), Keyword.fetch!(opts, :authenticator)}

    %{
      wardrik: wardrik,
      authenticator: authenticator,
      store: Keyword.fetch!(opts, :store),
      orgs: Keyword.fetch!(opts, :orgs),
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

  match _ do
    Wardrik.HTTP.call(conn, conn.assigns.daemon.http)
  end

  # Who asks is checked first, so a route answers 401 to anyone without a token, whatever they
  # ask for.
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
