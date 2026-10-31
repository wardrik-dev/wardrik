defmodule Wardrik.Operations.Owners do
  @moduledoc """
  Operations on what an org or person holds for their agents: connected accounts, secrets and
  MCP servers.
  """

  alias Wardrik.Error
  alias Wardrik.MCPTools
  alias Wardrik.Operations.Changes
  alias Wardrik.Owners
  alias Wardrik.Scope
  alias WardrikCore.Principal

  @app %{
    "issuer" => :issuer,
    "authorization_endpoint" => :authorization_endpoint,
    "token_endpoint" => :token_endpoint,
    "client_id" => :client_id,
    "client_auth" => :client_auth
  }
  @client_auths %{"post" => :post, "basic" => :basic}

  @doc """
  Lists the accounts the owner can connect, and whether each is connected.

  These are Wardrik's OAuth providers, plus each server that uses browser sign-in and serves the
  owner: their own, their org's for a person, and the deployment's. The nearest server of a name
  wins, and a server replaces a provider of the same name. Each account is the owner's own,
  whoever added its server. See `Wardrik.Owners`.
  """
  @spec connections(Scope.t(), map()) :: {:ok, map()}
  def connections(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    held = held(wardrik, owner)

    connections =
      for {provider, key} <- offered(wardrik, owner),
          do: %{"provider" => provider, "connected" => key in held}

    {:ok, %{"connections" => connections}}
  end

  @doc "Returns that the account is connected, or where the owner signs in to connect it."
  @spec connect(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def connect(%Scope{wardrik: wardrik}, %{"owner" => owner, "provider" => provider}) do
    with {:ok, key} <- offered(wardrik, owner, provider) do
      if key in held(wardrik, owner),
        do: {:ok, %{"provider" => provider, "connected" => true}},
        else: authorizing(wardrik, key, %Principal{id: owner}, %{"provider" => provider})
    end
  end

  @doc "Disconnects an account. The next call that needs it asks the owner to sign in again."
  @spec disconnect(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def disconnect(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "provider" => provider}) do
    with {:ok, key} <- offered(wardrik, owner, provider) do
      connected = key in held(wardrik, owner)

      if connected do
        :ok = WardrikVault.delete(Wardrik.vault(wardrik), %Principal{id: owner}, key)

        Changes.record_owned(scope, "secret.removed", owner, "secrets/" <> key, %{
          "secret" => %{"name" => key}
        })
      end

      {:ok, %{"provider" => provider, "connected" => connected}}
    end
  end

  @doc "Lists the owner's secrets by name, with each one's kind: a secret or a connected account."
  @spec secrets(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def secrets(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    with :ok <- keeps_secrets(wardrik) do
      secrets =
        for {^owner, name, kind} <- Wardrik.Sealed.list(wardrik),
            do: %{"name" => name, "kind" => Atom.to_string(kind)}

      {:ok, %{"secrets" => Enum.sort_by(secrets, & &1["name"])}}
    end
  end

  @doc "Lists the org's ceilings, with what its agents have spent in the current period."
  @spec ceilings(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def ceilings(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    with :ok <- an_org(owner),
         {:ok, spent} <- Wardrik.Orgs.spent(wardrik, owner) do
      ceilings = for {name, spend} <- Enum.sort(spent), do: ceiling(name, spend)
      {:ok, %{"ceilings" => ceilings}}
    end
  end

  defp an_org(owner) do
    case Owners.parse(owner) do
      {:ok, %{org: org, person: person}} when is_binary(org) and is_binary(person) ->
        {:error, Error.new(:invalid_request, "Ceilings are an org's: ask for #{org}'s.")}

      _org ->
        :ok
    end
  end

  defp ceiling(name, spend) do
    Wardrik.Type.json(%{
      ceiling: name,
      per: spend.per,
      on_exhausted: spend.on_exhausted,
      limit: amount(spend.limit),
      spent: amount(spend.spent),
      granted: amount(spend.granted),
      starts_over: spend.starts_over
    })
    |> Map.reject(fn {_key, value} -> value == nil end)
  end

  defp amount(amount), do: Map.reject(amount, fn {_kind, value} -> value == nil end)

  @doc "Seals a secret for the owner, replacing any with the same name."
  @spec put_secret(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def put_secret(%Scope{wardrik: wardrik} = scope, %{
        "owner" => owner,
        "name" => name,
        "value" => value
      }) do
    with :ok <- keeps_secrets(wardrik),
         :ok <- Wardrik.Sealed.put(wardrik, owner, name, value, actor: scope.principal),
         do: {:ok, nil}
  end

  @doc "Removes one of the owner's secrets. Succeeds if there's none."
  @spec delete_secret(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def delete_secret(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "name" => name}) do
    with :ok <- keeps_secrets(wardrik),
         :ok <- Wardrik.Sealed.delete(wardrik, owner, name, scope.principal),
         do: {:ok, nil}
  end

  defp keeps_secrets(%Wardrik{keys: []}),
    do:
      {:error,
       Error.new(
         :not_supported,
         "This Wardrik keeps no secrets. Give it :keys to seal them with."
       )}

  defp keeps_secrets(_wardrik), do: :ok

  @doc "Lists the MCP servers the owner added."
  @spec servers(Scope.t(), map()) :: {:ok, map()}
  def servers(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    store = store(wardrik)

    servers =
      for key <- WardrikStore.keys(store, prefix(owner)), do: listed(WardrikStore.get(store, key))

    {:ok, %{"servers" => servers}}
  end

  @doc "Adds an MCP server for the owner's agents. Returns whether they can call it now."
  @spec add(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def add(
        %Scope{wardrik: wardrik} = scope,
        %{"owner" => owner, "name" => name, "url" => url} = input
      ) do
    key = MCPTools.key(owner, name)

    with :ok <- unused(wardrik, owner, name),
         :ok <- reachable(wardrik, url),
         {:ok, reached, kind} <- reached(wardrik, owner, key, input),
         :ok <-
           added(
             wardrik,
             key,
             [transport: {:streamable_http, url: url}, prefix: name] ++
               narrowed(input) ++ reached
           ),
         {:ok, _vsn} <-
           WardrikStore.put(store(wardrik), prefix(owner) <> name, record(input, kind)) do
      data = %{"server" => %{"name" => name, "url" => url}}
      Changes.record_owned(scope, "server.added", owner, "servers/" <> name, data)
      answered(wardrik, %Principal{id: owner}, key, kind, name)
    end
  end

  @doc "Removes an MCP server the owner added, and its sign-ins. Returns the removed server."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "server" => name}) do
    store = store(wardrik)
    key = MCPTools.key(owner, name)

    case WardrikStore.get(store, prefix(owner) <> name) do
      nil ->
        {:error, Error.new(:not_found, "#{owner} has no server #{name}.")}

      record ->
        WardrikMCP.remove(Wardrik.mcp(wardrik), key)
        forget_sign_ins(wardrik, key, record["auth"])
        :ok = WardrikStore.delete(store, prefix(owner) <> name)

        Changes.record_owned(scope, "server.removed", owner, "servers/" <> name, %{
          "server" => %{"name" => name}
        })

        {:ok, listed(record)}
    end
  end

  defp providers(%Wardrik{oauth: nil}), do: []

  defp providers(wardrik),
    do:
      wardrik
      |> Wardrik.oauth()
      |> WardrikOAuth.providers()
      |> Enum.reject(&String.contains?(&1, ":"))

  defp held(%Wardrik{keys: []}, _owner), do: []
  defp held(wardrik, owner), do: WardrikVault.names(Wardrik.vault(wardrik), %Principal{id: owner})

  defp offered(wardrik, owner) do
    servers =
      owner
      |> Owners.chain()
      |> Enum.flat_map(fn added_by ->
        for name <- signed_in_servers(wardrik, added_by), do: {name, MCPTools.key(added_by, name)}
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    named = Enum.map(servers, &elem(&1, 0))

    providers =
      for provider <- providers(wardrik), provider not in named, do: {provider, provider}

    providers ++ servers
  end

  defp offered(wardrik, owner, provider) do
    case List.keyfind(offered(wardrik, owner), provider, 0) do
      {^provider, key} -> {:ok, key}
      nil -> {:error, Error.new(:not_found, "There's no account #{provider} to connect.")}
    end
  end

  defp signed_in_servers(wardrik, owner) do
    store = store(wardrik)

    for key <- WardrikStore.keys(store, prefix(owner)),
        %{"name" => name, "auth" => "oauth"} <- [WardrikStore.get(store, key)],
        do: name
  end

  defp authorizing(wardrik, provider, principal, answer) do
    case WardrikOAuth.authorize(Wardrik.oauth(wardrik), provider, principal) do
      {:ok, url} ->
        {:ok, Map.merge(answer, %{"connected" => false, "authorization" => %{"url" => url}})}

      {:error, reason} ->
        {:error,
         Error.new(:unavailable, "#{provider} can't be signed in to now: #{inspect(reason)}")}
    end
  end

  defp unused(wardrik, owner, name) do
    if WardrikStore.get(store(wardrik), prefix(owner) <> name) == nil,
      do: :ok,
      else: {:error, Error.new(:conflict, "#{owner} has a server #{name} already.")}
  end

  defp reachable(wardrik, url) do
    case wardrik.egress.(url) do
      :ok ->
        :ok

      {:error, why} ->
        {:error, Error.new(:invalid_request, "The server can't be reached: #{why}.")}
    end
  end

  defp reached(_wardrik, _owner, _key, %{"auth" => %{"none" => _none}}), do: {:ok, [], "none"}

  defp reached(%Wardrik{keys: []}, _owner, _key, %{"auth" => %{"secret" => _secret}}),
    do:
      {:error, Error.new(:not_supported, "A server's secret needs Wardrik to keep credentials.")}

  defp reached(wardrik, owner, _key, %{"auth" => %{"secret" => %{"name" => name} = secret}}) do
    case WardrikVault.fetch(Wardrik.vault(wardrik), %Principal{id: owner}, name) do
      {:ok, value} ->
        header = Map.get(secret, "header", "authorization")
        sent = String.trim("#{Map.get(secret, "scheme", "Bearer")} #{value}")
        {:ok, headers(header, sent), "secret"}

      {:error, _reason} ->
        {:error, Error.new(:invalid_request, "#{owner} holds no secret #{name}.")}
    end
  end

  defp reached(%Wardrik{oauth: nil}, _owner, _key, %{"auth" => %{"oauth" => _oauth}}),
    do: {:error, Error.new(:not_supported, "Signing in to a server needs Wardrik's oauth.")}

  defp reached(wardrik, owner, key, %{"auth" => %{"oauth" => oauth}, "url" => url}) do
    with {:ok, secret} <- client_secret(wardrik, owner, oauth["client_secret"]),
         :ok <- added_provider(wardrik, key, app(url, oauth) ++ secret),
         do: {:ok, [credential_name: key], "oauth"}
  end

  defp client_secret(_wardrik, _owner, nil), do: {:ok, []}

  defp client_secret(%Wardrik{keys: []}, _owner, _secret),
    do:
      {:error,
       Error.new(:not_supported, "An app's client secret needs Wardrik to keep credentials.")}

  defp client_secret(wardrik, owner, %{"name" => name}) do
    case WardrikVault.fetch(Wardrik.vault(wardrik), %Principal{id: owner}, name) do
      {:ok, value} ->
        {:ok, [client_secret: value]}

      {:error, _reason} ->
        {:error, Error.new(:invalid_request, "#{owner} holds no secret #{name}.")}
    end
  end

  defp app(url, oauth) do
    given =
      oauth
      |> Map.take(Map.keys(@app))
      |> Enum.map(fn {field, value} -> app_option(field, value) end)

    [resource: url, scopes: Map.get(oauth, "scopes", [])] ++ given
  end

  defp app_option("client_auth", how), do: {:client_auth, Map.fetch!(@client_auths, how)}
  defp app_option(field, value), do: {Map.fetch!(@app, field), value}

  defp added_provider(wardrik, key, opts) do
    case WardrikOAuth.add_provider(Wardrik.oauth(wardrik), key, opts) do
      :ok ->
        :ok

      {:error, why} ->
        {:error, Error.new(:invalid_request, "The server can't be signed in to: #{why}")}
    end
  end

  defp headers(header, sent), do: [headers: %{header => sent}]

  defp added(wardrik, key, opts) do
    {headers, opts} = Keyword.pop(opts, :headers)
    opts = with_headers(opts, headers)

    case WardrikMCP.add(Wardrik.mcp(wardrik), key, opts) do
      :ok -> :ok
      {:error, why} -> {:error, Error.new(:invalid_request, "The server doesn't read: #{why}")}
    end
  end

  defp with_headers(opts, nil), do: opts

  defp with_headers(opts, headers) do
    {:streamable_http, transport} = Keyword.fetch!(opts, :transport)
    Keyword.put(opts, :transport, {:streamable_http, Keyword.put(transport, :headers, headers)})
  end

  defp narrowed(input) do
    for {key, value} <- [only: input["only"], except: input["except"]],
        value != nil,
        do: {key, value}
  end

  defp answered(wardrik, principal, key, "oauth", name) do
    if key in held(wardrik, principal.id),
      do: {:ok, %{"server" => name, "connected" => true}},
      else: authorizing(wardrik, key, principal, %{"server" => name})
  end

  defp answered(_wardrik, _principal, _key, _kind, name),
    do: {:ok, %{"server" => name, "connected" => true}}

  defp forget_sign_ins(wardrik, key, "oauth") do
    vault = Wardrik.vault(wardrik)

    for {id, ^key, _kind} <- WardrikVault.list(vault),
        do: WardrikVault.delete(vault, %Principal{id: id}, key)

    WardrikOAuth.remove_provider(Wardrik.oauth(wardrik), key)
  end

  defp forget_sign_ins(_wardrik, _key, _kind), do: :ok

  defp record(input, kind), do: %{"name" => input["name"], "url" => input["url"], "auth" => kind}
  defp listed(record), do: Map.take(record, ["name", "url", "auth"])

  defp prefix(owner), do: "servers/" <> URI.encode_www_form(owner) <> "/"

  defp store(%Wardrik{store: store}), do: WardrikStore.scope(store, "wardrik")
end
