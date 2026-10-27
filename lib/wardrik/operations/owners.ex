defmodule Wardrik.Operations.Owners do
  @moduledoc """
  The operations on what an org or a person holds for their agents: the accounts they connect, the
  secrets they seal, and the MCP servers they add.
  """

  alias Wardrik.Error
  alias Wardrik.MCPTools
  alias Wardrik.Operations.Changes
  alias Wardrik.Scope
  alias WardrikCore.Principal

  @doc "Lists the accounts the owner is offered, and whether they hold each."
  @spec connections(Scope.t(), map()) :: {:ok, map()}
  def connections(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    held = held(wardrik, owner)

    connections =
      for provider <- providers(wardrik),
          do: %{"provider" => provider, "connected" => provider in held}

    {:ok, %{"connections" => connections}}
  end

  @doc "Answers that the owner holds an account, or where they authorize it."
  @spec connect(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def connect(%Scope{wardrik: wardrik}, %{"owner" => owner, "provider" => provider}) do
    with :ok <- offered(wardrik, provider) do
      if provider in held(wardrik, owner),
        do: {:ok, %{"provider" => provider, "connected" => true}},
        else: authorizing(wardrik, provider, %Principal{id: owner}, %{"provider" => provider})
    end
  end

  @doc "Forgets an account the owner holds, so the next call that needs it asks again."
  @spec disconnect(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def disconnect(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "provider" => provider}) do
    with :ok <- offered(wardrik, provider) do
      connected = provider in held(wardrik, owner)

      if connected do
        :ok = WardrikVault.delete(Wardrik.vault(wardrik), %Principal{id: owner}, provider)

        Changes.record_owned(scope, "secret.removed", owner, "secrets/" <> provider, %{
          "secret" => %{"name" => provider}
        })
      end

      {:ok, %{"provider" => provider, "connected" => connected}}
    end
  end

  @doc "Lists the secrets the owner holds, by name, and whether each is sealed or connected."
  @spec secrets(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def secrets(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    with :ok <- keeps_secrets(wardrik) do
      secrets =
        for {^owner, name, kind} <- Wardrik.Sealed.list(wardrik),
            do: %{"name" => name, "kind" => Atom.to_string(kind)}

      {:ok, %{"secrets" => Enum.sort_by(secrets, & &1["name"])}}
    end
  end

  @doc "Lists the org's ceilings, each with what its agents have spent against it in its period now."
  @spec ceilings(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def ceilings(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    with :ok <- an_org(owner),
         {:ok, spent} <- Wardrik.Orgs.spent(wardrik, owner) do
      ceilings = for {name, spend} <- Enum.sort(spent), do: ceiling(name, spend)
      {:ok, %{"ceilings" => ceilings}}
    end
  end

  defp an_org(owner) do
    case String.split(owner, "/") do
      [_org] ->
        :ok

      [org | _person] ->
        {:error, Error.new(:invalid_request, "Ceilings are an org's: ask for #{org}'s.")}
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

  @doc "Seals a secret as the owner's, in place of any of the same name."
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

  @doc "Removes the owner's secret of a name. Removing none is as removing one."
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

  @doc "Adds an MCP server for the owner's agents, and answers whether they can call it now."
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
             [transport: {:streamable_http, base_url: url}, prefix: name] ++
               narrowed(input) ++ reached
           ),
         {:ok, _vsn} <-
           WardrikStore.put(store(wardrik), prefix(owner) <> name, record(input, kind)) do
      data = %{"server" => %{"name" => name, "url" => url}}
      Changes.record_owned(scope, "server.added", owner, "servers/" <> name, data)
      answered(wardrik, scope.principal, key, kind, name)
    end
  end

  @doc "Removes an MCP server the owner added, with the sign-ins to it, and answers it as it was."
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

  defp offered(wardrik, provider) do
    if provider in providers(wardrik),
      do: :ok,
      else: {:error, Error.new(:not_found, "There's no account #{provider} to connect.")}
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

  defp reached(wardrik, _owner, key, %{"auth" => %{"oauth" => oauth}, "url" => url}) do
    opts = [resource: url, scopes: Map.get(oauth, "scopes", [])]

    case WardrikOAuth.add_provider(Wardrik.oauth(wardrik), key, opts) do
      :ok ->
        {:ok, [credential_name: key], "oauth"}

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
