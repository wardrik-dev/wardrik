defmodule Wardrik.Operations.Servers do
  @moduledoc false

  # The MCP servers owners keep for agents. Each runs in `Wardrik.MCP` under its reference, as
  # `acme:crm`, on every node. The deployment's are those Wardrik starts with, under their names.
  #
  #   * Agents sign in with nothing, a secret sealed for `header` (read as each connection
  #     starts), an OAuth app the owner may use, or the server's own app, named `server:` and its
  #     name, kept and forgotten with it.
  #   * Your resolver gives each agent its servers. Using another owner's is `mcp_server.use`.
  #   * `Wardrik.MCP` keeps what each node runs the server with. Its record here keeps what it
  #     was added with, and the credential it signs in with.

  @behaviour Wardrik.Owned
  @behaviour Wardrik.Format

  alias Wardrik.Error
  alias Wardrik.OAuth.Apps
  alias Wardrik.Operations.Changes
  alias Wardrik.Owned
  alias Wardrik.Principal
  alias Wardrik.Scope

  @use {"mcp_server.use", :mcp_server}
  @fields ~w(owner name url auth provider credential)a

  @impl Wardrik.Owned
  def kind, do: "servers"

  @impl Wardrik.Format
  def version, do: 1

  @impl Wardrik.Format
  def dump(record), do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(record, &1)})

  @impl Wardrik.Format
  def load(1, record), do: {:ok, Map.new(@fields, &{&1, Map.fetch!(record, Atom.to_string(&1))})}

  @doc "Lists the owner's servers. The deployment's include those Wardrik starts with."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    declared = if owner == Owned.deployment(), do: declared(wardrik), else: []
    kept = for record <- Owned.own(wardrik, __MODULE__, owner), do: listed(record)
    {:ok, %{"servers" => declared ++ kept}}
  end

  @doc """
  Adds the server `input` describes for the owner, and starts it on every node. Answers whether
  agents can call it now, or where the owner signs in first.
  """
  @spec add(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def add(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "name" => name} = input) do
    key = Owned.reference(owner, name)

    with :ok <- unused(wardrik, owner, name),
         :ok <- reachable(wardrik, input["url"]),
         {:ok, reached, auth} <- signs_in(wardrik, owner, input),
         opts = options(owner, input, reached),
         :ok <- started(wardrik, key, opts),
         :ok <- Owned.put(wardrik, __MODULE__, record(owner, input, auth, opts)) do
      :ok = :erpc.multicast(Node.list(), Wardrik.MCP, :add, [Wardrik.mcp(wardrik), key, opts])
      changed(scope, "server.added", {owner, name, %{"url" => input["url"]}})
      answered(wardrik, owner, opts[:credential_name], name)
    end
  end

  @doc "Removes one of the owner's servers and the sign-ins to it, and stops it on every node."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "name" => name}) do
    key = Owned.reference(owner, name)

    case Owned.get(wardrik, __MODULE__, key) do
      nil ->
        not_removed(wardrik, owner, name)

      record ->
        mcp = Wardrik.mcp(wardrik)
        _stopped = Wardrik.MCP.remove(mcp, key)
        :ok = :erpc.multicast(Node.list(), Wardrik.MCP, :remove, [mcp, key])
        forget_sign_ins(wardrik, record)
        :ok = Owned.delete(wardrik, __MODULE__, owner, name)
        changed(scope, "server.removed", {owner, name, %{}})
        {:ok, listed(record)}
    end
  end

  @doc "Returns who keeps the server Wardrik runs as `key`, or `nil` if there's none."
  @spec owner(Wardrik.t(), String.t()) :: String.t() | nil
  def owner(wardrik, key) do
    cond do
      declared?(wardrik, key) -> Owned.deployment()
      record = Owned.get(wardrik, __MODULE__, key) -> record.owner
      true -> nil
    end
  end

  @doc """
  Returns the servers `principal`'s agents reach, by name, as `Wardrik.Resolved`'s `:servers`
  takes them: its own of each name, else the one another owner lets it use, else the
  deployment's. A name more than one other owner's would do for is left out.
  """
  @spec reached(Wardrik.t(), Principal.t()) :: %{String.t() => String.t()}
  def reached(wardrik, principal) do
    candidates =
      for(
        record <- Owned.all(wardrik, __MODULE__),
        do: %{
          owner: record.owner,
          name: record.name,
          key: Owned.reference(record.owner, record.name)
        }
      ) ++
        for(
          {name, _opts} <- wardrik.mcp,
          name = to_string(name),
          do: %{owner: Owned.deployment(), name: name, key: name}
        )

    for {name, named} <- Enum.group_by(candidates, & &1.name),
        %{key: key} <- [Owned.chosen(wardrik, principal, named, @use)],
        into: %{},
        do: {name, key}
  end

  defp declared(wardrik) do
    for {name, opts} <- wardrik.mcp do
      server = %{
        "owner" => Owned.deployment(),
        "name" => to_string(name),
        "source" => "config",
        "auth" => declared_auth(opts)
      }

      put(server, "url", url(opts[:transport]))
    end
  end

  defp url({:streamable_http, http}), do: http[:url]
  defp url(_stdio), do: nil

  defp declared_auth(opts) do
    cond do
      opts[:credential_name] -> "oauth"
      headers?(opts[:transport]) -> "secret"
      true -> "none"
    end
  end

  defp headers?({:streamable_http, http}), do: Enum.any?(http[:headers] || %{})
  defp headers?(_stdio), do: false

  defp unused(wardrik, owner, name) do
    cond do
      Owned.get(wardrik, __MODULE__, Owned.reference(owner, name)) != nil -> conflict(owner, name)
      owner == Owned.deployment() and declared?(wardrik, name) -> conflict(owner, name)
      true -> :ok
    end
  end

  defp conflict(owner, name),
    do: {:error, Error.new(:conflict, "#{owner} has a server #{name} already.")}

  defp not_removed(wardrik, owner, name) do
    if owner == Owned.deployment() and declared?(wardrik, name),
      do: {:error, Error.new(:invalid_request, "#{name} is an MCP server Wardrik starts with.")},
      else: {:error, Error.new(:not_found, "#{owner} has no server #{name}.")}
  end

  defp declared?(wardrik, name), do: Enum.any?(wardrik.mcp, &(to_string(elem(&1, 0)) == name))

  defp reachable(wardrik, url) do
    case wardrik.egress.(url) do
      :ok ->
        :ok

      {:error, why} ->
        {:error, Error.new(:invalid_request, "The server can't be reached: #{why}.")}
    end
  end

  defp signs_in(_wardrik, _owner, %{"auth" => %{"none" => _none}}), do: {:ok, [], "none"}

  # The header names the secret, read as each connection starts, so a new value takes effect.
  defp signs_in(wardrik, owner, %{"auth" => %{"secret" => %{"name" => name} = secret}}) do
    vault = Wardrik.vault(wardrik)

    if {owner, name, :header} in Wardrik.Vault.list(vault) do
      sent = sent(Map.get(secret, "scheme", "Bearer"), name)
      {:ok, [headers: %{Map.get(secret, "header", "authorization") => sent}], "secret"}
    else
      {:error,
       Error.new(:invalid_request, "#{owner} holds no secret #{name} sealed as a header.")}
    end
  end

  defp signs_in(%Wardrik{oauth: nil}, _owner, %{"auth" => %{"oauth" => _oauth}}),
    do: {:error, Error.new(:not_supported, "Signing in to a server needs Wardrik's :oauth.")}

  # A server naming an OAuth app signs in with the one its owner would. Connecting that app once
  # covers the server.
  defp signs_in(wardrik, owner, %{"auth" => %{"oauth" => %{"provider" => provider}}}) do
    case Apps.chosen(wardrik, %Principal{id: owner}, provider) do
      %{} = app -> {:ok, [credential_name: Apps.reference(app)], "oauth"}
      _none -> {:error, Error.new(:invalid_request, "#{owner} has no OAuth app #{provider}.")}
    end
  end

  # Its own sign-in is an OAuth app named for it, which only it uses.
  defp signs_in(wardrik, owner, %{"auth" => %{"oauth" => oauth}} = input) do
    app = Map.merge(oauth, %{"name" => "server:" <> input["name"], "resource" => input["url"]})

    case Apps.keep(wardrik, owner, app) do
      {:ok, kept} ->
        {:ok, [credential_name: Apps.reference(kept)], "oauth"}

      {:error, %Error{message: why}} ->
        {:error, Error.new(:invalid_request, "#{input["name"]} can't be signed in with: #{why}")}
    end
  end

  defp sent("", name), do: {:secret, name}
  defp sent(scheme, name), do: [scheme <> " ", {:secret, name}]

  defp options(owner, %{"name" => name, "url" => url} = input, reached) do
    {headers, reached} = Keyword.pop(reached, :headers)
    http = if headers, do: [url: url, headers: headers], else: [url: url]

    narrowed =
      for {key, value} <- [only: input["only"], except: input["except"]],
          value != nil,
          do: {key, value}

    [transport: {:streamable_http, http}, prefix: name, owner: owner] ++ narrowed ++ reached
  end

  defp started(wardrik, key, opts) do
    mcp = Wardrik.mcp(wardrik)

    case Wardrik.MCP.add(mcp, key, opts) do
      :ok -> :ok
      {:error, why} -> {:error, Error.new(:invalid_request, "The server doesn't read: #{why}")}
    end
  end

  defp record(owner, input, auth, opts) do
    %{
      owner: owner,
      name: input["name"],
      url: input["url"],
      auth: auth,
      provider: get_in(input, ["auth", "oauth", "provider"]),
      credential: opts[:credential_name]
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

  defp answered(wardrik, owner, credential, name) do
    cond do
      credential == nil -> {:ok, %{"server" => name, "connected" => true}}
      credential in held(wardrik, owner) -> {:ok, %{"server" => name, "connected" => true}}
      true -> authorizing(wardrik, {owner, credential}, name)
    end
  end

  defp held(wardrik, owner) do
    wardrik
    |> Wardrik.vault()
    |> Wardrik.Vault.names(%Principal{id: owner})
  end

  defp authorizing(wardrik, {owner, credential}, name) do
    case Wardrik.sign_in(wardrik, credential, %Principal{id: owner}) do
      {:ok, started} ->
        authorization = Map.new(started, fn {key, value} -> {Atom.to_string(key), value} end)
        {:ok, %{"server" => name, "connected" => false, "authorization" => authorization}}

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{name} can't be signed in to now: #{inspect(reason)}")}
    end
  end

  # A server that names an OAuth app leaves the app, and the accounts connected with it, alone.
  defp forget_sign_ins(wardrik, %{auth: "oauth", provider: nil, credential: credential} = record) do
    vault = Wardrik.vault(wardrik)

    for {id, ^credential, _kind} <- Wardrik.Vault.list(vault),
        do: Wardrik.Vault.delete(vault, %Principal{id: id}, credential)

    _forgotten = Apps.forget(wardrik, record.owner, "server:" <> record.name)
    :ok
  end

  defp forget_sign_ins(_wardrik, _record), do: :ok

  defp changed(scope, type, {owner, name, data}),
    do:
      Changes.record_deployment(scope,
        type: type,
        subject: "servers/" <> name,
        data: %{"server" => Map.put(data, "name", name), "owner" => owner}
      )

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end
