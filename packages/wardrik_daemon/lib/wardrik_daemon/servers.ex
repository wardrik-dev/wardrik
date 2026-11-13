defmodule WardrikDaemon.Servers do
  @moduledoc """
  The MCP servers orgs and people add for their agents, served at `/v1/owners/{owner}/servers`.

      wardrik server add crm --url https://crm.example.com/mcp --secret CRM_KEY --org acme

    * Each runs in `Wardrik.MCP` as `owner:name`, on every node.
    * An org's server reaches its agents and its people's. A person's reaches theirs alone.
      The nearest of a name wins. See `WardrikDaemon.Resolver`.
    * Agents sign in with nothing (`%{"none" => %{}}`), a secret sealed for `header`
      (`%{"secret" => %{"name" => "CRM_KEY"}}`), or their owner's account (`%{"oauth" => ...}`).
    * Adding or removing one records `server.added` or `server.removed` in the audit.
  """

  alias Wardrik.Error
  alias Wardrik.OAuth.Apps
  alias WardrikCore.Principal
  alias WardrikDaemon.Config.Orgs
  alias WardrikDaemon.Owned
  alias WardrikDaemon.Owners

  @kind "servers"

  @typedoc "The Wardrik's `:wardrik` name, the daemon's `:store`, and `:config`."
  @type daemon() :: %{
          required(:wardrik) => atom(),
          required(:store) => Wardrik.Store.t(),
          required(:config) => WardrikDaemon.Config.t(),
          optional(atom()) => term()
        }

  @doc """
  Returns the `Wardrik.MCP` name of `owner`'s server `name`.

      WardrikDaemon.Servers.key("acme", "github")
      #=> "acme:github"
  """
  @spec key(String.t(), String.t()) :: String.t()
  def key(owner, name), do: owner <> ":" <> name

  @doc "Lists the servers `owner`'s agents reach, nearest first. Never their headers."
  @spec list(daemon(), String.t()) :: [map()]
  def list(%{store: store, config: config}, owner) do
    store
    |> Owned.along(@kind, owner)
    |> Enum.map(&listed/1)
    |> Kernel.++(configured(config, Owners.org(owner)))
    |> Owned.nearest()
  end

  @doc "Returns the servers `owner`'s agents reach by name, as their `Wardrik.MCP` names."
  @spec reached(daemon(), String.t()) :: [{String.t(), String.t()}]
  def reached(%{store: store, config: config}, owner) do
    added =
      for %{owner: owner, name: name} <- Owned.along(store, @kind, owner),
          do: {name, key(owner, name)}

    added ++ for(%{"name" => name} <- configured(config, Owners.org(owner)), do: {name, name})
  end

  defp configured(config, org) do
    for {name, opts} <- config.mcp,
        name = to_string(name),
        Orgs.serves?(config, kind: :mcp, name: name, org: org) do
      %{
        "owner" => "deployment",
        "name" => name,
        "source" => "config",
        "auth" => configured_auth(opts)
      }
      |> put("url", url(opts[:transport]))
    end
  end

  defp url({:streamable_http, http}), do: http[:url]
  defp url(_stdio), do: nil

  defp configured_auth(opts) do
    cond do
      opts[:credential_name] -> "oauth"
      headers?(opts[:transport]) -> "secret"
      true -> "none"
    end
  end

  defp headers?({:streamable_http, http}), do: Enum.any?(http[:headers] || %{})
  defp headers?(_stdio), do: false

  @doc """
  Adds the server `input` describes for `owner`, as `actor`, and starts it on every node.

  Returns whether agents can call it now, or where `owner` signs in first.
  """
  @spec add(daemon(), {String.t(), map()}, Principal.t() | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def add(%{wardrik: wardrik, store: store} = daemon, {owner, %{"name" => name} = input}, actor) do
    running = Wardrik.Instance.fetch!(wardrik)
    key = key(owner, name)

    with :ok <- unused(store, owner, name),
         :ok <- reachable(running, input["url"]),
         {:ok, reached, auth} <- signs_in({daemon, running}, {owner, key}, input),
         opts = options(owner, input, reached),
         :ok <- started(running, key, opts),
         {:ok, _vsn} <-
           Wardrik.Store.put(
             store,
             Owned.path(@kind, owner, name),
             record(owner, input, auth, opts)
           ) do
      :ok = :erpc.multicast(Node.list(), Wardrik.MCP, :add, [Wardrik.mcp(running), key, opts])
      changed(running, "server.added", {owner, name, %{"url" => input["url"]}}, actor)
      answered(running, owner, reached[:credential_name], name)
    end
  end

  @doc "Removes `owner`'s server `name` and its sign-ins, as `actor`, and stops it on every node."
  @spec remove(daemon(), {String.t(), String.t()}, Principal.t() | nil) ::
          {:ok, map()} | {:error, Error.t()}
  def remove(%{wardrik: wardrik, store: store} = daemon, {owner, name}, actor) do
    running = Wardrik.Instance.fetch!(wardrik)
    key = key(owner, name)

    case Wardrik.Store.get(store, Owned.path(@kind, owner, name)) do
      nil ->
        not_removed(daemon, owner, name)

      record ->
        _stopped = Wardrik.MCP.remove(Wardrik.mcp(running), key)
        :ok = :erpc.multicast(Node.list(), Wardrik.MCP, :remove, [Wardrik.mcp(running), key])
        forget_sign_ins({daemon, running}, {owner, key}, record)
        :ok = Wardrik.Store.delete(store, Owned.path(@kind, owner, name))
        changed(running, "server.removed", {owner, name, %{}}, actor)
        {:ok, listed(record)}
    end
  end

  @doc """
  Starts each stored server that isn't running, and stops each running one no longer stored.
  """
  @spec start(atom(), Wardrik.Store.t()) :: :ok
  def start(wardrik, store) do
    mcp = Wardrik.mcp(wardrik)
    kept = Map.new(Owned.all(store, @kind), &{key(&1.owner, &1.name), &1.opts})
    running = Wardrik.MCP.servers(mcp)

    for {key, opts} <- kept, key not in running, do: _started = Wardrik.MCP.add(mcp, key, opts)

    for key <- running,
        String.contains?(key, ":"),
        not Map.has_key?(kept, key),
        do: _stopped = Wardrik.MCP.remove(mcp, key)

    :ok
  end

  defp not_removed(%{config: config}, owner, name) do
    if owner == "deployment" and Enum.any?(config.mcp, &(to_string(elem(&1, 0)) == name)),
      do: {:error, Error.new(:invalid_request, "#{name} is an MCP server config.yaml starts.")},
      else: {:error, Error.new(:not_found, "#{owner} has no server #{name}.")}
  end

  defp unused(store, owner, name) do
    if Wardrik.Store.get(store, Owned.path(@kind, owner, name)) == nil,
      do: :ok,
      else: {:error, Error.new(:conflict, "#{owner} has a server #{name} already.")}
  end

  defp reachable(running, url) do
    case running.egress.(url) do
      :ok ->
        :ok

      {:error, why} ->
        {:error, Error.new(:invalid_request, "The server can't be reached: #{why}.")}
    end
  end

  defp signs_in(_running, _owned, %{"auth" => %{"none" => _none}}), do: {:ok, [], "none"}

  # The header names the secret, read as each connection starts, so a new value takes effect.
  defp signs_in(
         {_daemon, running},
         {owner, _key},
         %{"auth" => %{"secret" => %{"name" => name} = secret}}
       ) do
    if holds?(running, owner, name, :header) do
      sent = sent(Map.get(secret, "scheme", "Bearer"), name)
      {:ok, [headers: %{Map.get(secret, "header", "authorization") => sent}], "secret"}
    else
      {:error,
       Error.new(:invalid_request, "#{owner} holds no secret #{name} sealed as a header.")}
    end
  end

  defp signs_in({_daemon, %Wardrik{oauth: nil}}, _owned, %{"auth" => %{"oauth" => _oauth}}),
    do: {:error, Error.new(:not_supported, "Signing in to a server needs config.yaml's oauth.")}

  # A server naming an OAuth app signs in with the one its owner would: its own, one it may use,
  # or the deployment's. Connecting that app once covers the server.
  defp signs_in({_daemon, running}, {owner, _key}, %{
         "auth" => %{"oauth" => %{"provider" => provider}}
       }) do
    case Apps.chosen(running, %Principal{id: owner}, provider) do
      %{} = app -> {:ok, [credential_name: Apps.reference(app)], "oauth"}
      _none -> {:error, Error.new(:invalid_request, "#{owner} has no OAuth app #{provider}.")}
    end
  end

  # Its own sign-in is an OAuth app named for it, which only it uses.
  defp signs_in({_daemon, running}, {owner, _key}, %{"auth" => %{"oauth" => oauth}} = input) do
    app = Map.merge(oauth, %{"name" => "server:" <> input["name"], "resource" => input["url"]})

    case Apps.keep(running, owner, app) do
      {:ok, kept} ->
        {:ok, [credential_name: Apps.reference(kept)], "oauth"}

      {:error, %Error{message: why}} ->
        {:error, Error.new(:invalid_request, "#{input["name"]} can't be signed in with: #{why}")}
    end
  end

  defp sent("", name), do: {:secret, name}
  defp sent(scheme, name), do: [scheme <> " ", {:secret, name}]

  defp holds?(running, owner, name, kind),
    do: {owner, name, kind} in Wardrik.Vault.list(Wardrik.vault(running))

  defp options(owner, %{"name" => name, "url" => url} = input, reached) do
    {headers, reached} = Keyword.pop(reached, :headers)
    http = if headers, do: [url: url, headers: headers], else: [url: url]

    narrowed =
      for {key, value} <- [only: input["only"], except: input["except"]],
          value != nil,
          do: {key, value}

    [transport: {:streamable_http, http}, prefix: name, owner: owner] ++ narrowed ++ reached
  end

  defp started(running, key, opts) do
    case Wardrik.MCP.add(Wardrik.mcp(running), key, opts) do
      :ok -> :ok
      {:error, why} -> {:error, Error.new(:invalid_request, "The server doesn't read: #{why}")}
    end
  end

  defp record(owner, input, auth, opts) do
    provider = get_in(input, ["auth", "oauth", "provider"])

    %{
      owner: owner,
      name: input["name"],
      url: input["url"],
      auth: auth,
      provider: provider,
      opts: opts
    }
  end

  defp listed(record) do
    %{
      "owner" => record.owner,
      "name" => record.name,
      "source" => "runtime",
      "url" => record.url,
      "auth" => record.auth
    }
  end

  defp answered(running, owner, credential, name) do
    cond do
      credential == nil -> {:ok, %{"server" => name, "connected" => true}}
      credential in held(running, owner) -> {:ok, %{"server" => name, "connected" => true}}
      true -> authorizing(running, {owner, credential}, name)
    end
  end

  defp held(running, owner),
    do: Wardrik.Vault.names(Wardrik.vault(running), %Principal{id: owner})

  defp authorizing(running, {owner, credential}, name) do
    case Wardrik.sign_in(running, credential, %Principal{id: owner}) do
      {:ok, started} ->
        authorization = Map.new(started, fn {key, value} -> {Atom.to_string(key), value} end)
        {:ok, %{"server" => name, "connected" => false, "authorization" => authorization}}

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{name} can't be signed in to now: #{inspect(reason)}")}
    end
  end

  # A server that names an OAuth app leaves the app, and the accounts connected with it, alone.
  defp forget_sign_ins(
         {_daemon, running},
         {owner, _key},
         %{auth: "oauth", provider: nil} = record
       ) do
    vault = Wardrik.vault(running)
    credential = Keyword.fetch!(record.opts, :credential_name)

    for {id, ^credential, _kind} <- Wardrik.Vault.list(vault),
        do: Wardrik.Vault.delete(vault, %Principal{id: id}, credential)

    _forgotten = Apps.forget(running, owner, "server:" <> record.name)
    :ok
  end

  defp forget_sign_ins(_running, _owned, _record), do: :ok

  defp changed(running, type, {owner, name, data}, actor) do
    change =
      {type, "servers/" <> name, %{"server" => Map.put(data, "name", name), "owner" => owner}}

    :ok = Wardrik.EventLog.record(Wardrik.events(running), change, actor: actor)
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
