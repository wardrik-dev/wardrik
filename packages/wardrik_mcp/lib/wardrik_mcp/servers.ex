defmodule WardrikMCP.Servers do
  @moduledoc """
  The `Wardrik.Servers` orgs and people add MCP servers through, kept in
  `:store` as `WardrikMCP.Remote`s and reached by each node's
  `WardrikMCP.Remotes`. A server its owner signs in to is one of `:oauth`'s
  providers, through `WardrikMCP.Servers.Providers`, and its token is kept
  in `:vault`:

      oauth = WardrikOAuth.new(added: %WardrikMCP.Servers.Providers{store: store})
      vault = WardrikVault.new(store: store, keys: keys, grants: oauth)
      servers = %WardrikMCP.Servers{store: store, oauth: oauth, vault: vault}

  A server's URL is held to `:check` as it is added, and again as each
  node starts its connection: an `https` URL whose host has public
  addresses alone, as `WardrikMCP.Remote.reachable/1` checks, unless it says.
  An owner's server may not take the name a server of the deployment's own
  that serves them already prefixes its tools with, since their tools would
  be named alike, nor the name of one of `:oauth`'s configured providers,
  whose sign-in its credential would resolve. Adding one its owner signs in
  to answers the link to sign in at, and one whose sign-in cannot start is
  not kept. Removing one stops every connection to it, on every node, and
  forgets its token.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Servers.Key
  alias Wardrik.Servers.Server
  alias WardrikMCP.Auth
  alias WardrikMCP.Remote

  @enforce_keys [:store, :oauth, :vault]
  defstruct [:store, :oauth, :vault, check: &Remote.reachable/1]

  @type t() :: %__MODULE__{
          store: WardrikStore.t(),
          oauth: WardrikOAuth.t(),
          vault: WardrikVault.t(),
          check: (String.t() -> :ok | {:error, term()})
        }

  @doc false
  @spec list(t(), Prefix.t()) :: [Server.t()]
  def list(%__MODULE__{store: store}, owner) do
    for remote <- Remote.list(store, owner),
        do: %Server{
          name: remote.key.name,
          url: remote.url,
          auth: Auth.name(remote.auth),
          secret: secret(remote.auth)
        }
  end

  defp secret(%Auth.Secret{name: name}), do: name
  defp secret(_auth), do: nil

  @doc false
  @spec add(t(), Prefix.t(), keyword()) ::
          {:ok, :connected} | {:ok, Wardrik.Call.Ask.link()} | {:error, Error.t()}
  def add(%__MODULE__{} = servers, owner, opts) do
    key = Key.new(owner, Keyword.fetch!(opts, :name))

    with {:ok, remote} <- decoded(key, Keyword.fetch!(opts, :fields)),
         :ok <- reachable(servers, remote),
         :ok <- unclaimed(servers, key),
         :ok <- kept(servers, remote) do
      signed_in(servers, remote, Keyword.get(opts, :by))
    end
  end

  @doc false
  @spec remove(t(), Prefix.t(), keyword()) :: :ok | {:error, Error.t()}
  def remove(%__MODULE__{store: store} = servers, owner, opts) do
    key = Key.new(owner, Keyword.fetch!(opts, :name))

    case Remote.fetch(store, key) do
      {:ok, remote} ->
        :ok = Remote.delete(store, key)
        :erpc.multicast(Node.list(), WardrikMCP, :close, [key])
        :ok = WardrikMCP.close(key)
        forget(servers, remote)

      :error ->
        {:error, Error.new(:not_found, "#{owner} added no server named #{key.name}.")}
    end
  end

  defp decoded(key, fields) do
    case Remote.decode(key, fields) do
      {:ok, remote} -> {:ok, remote}
      {:error, message} -> {:error, Error.new(:invalid, message)}
    end
  end

  defp reachable(%__MODULE__{check: check}, remote) do
    case check.(remote.url) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(:invalid, "#{remote.url} cannot be reached from here: #{inspect(reason)}")}
    end
  end

  # A server of the deployment's own that serves the owner names its tools
  # with its prefix, and so would the owner's of that name; a configured
  # provider of that name is the sign-in its credential would resolve.
  defp unclaimed(%__MODULE__{oauth: oauth}, %Key{owner: owner, name: name}) do
    cond do
      Enum.any?(WardrikMCP.Supervisor.servers(), &(&1.prefix == name and serves?(&1, owner))) ->
        taken("#{name} names a server this deployment offers #{owner}")

      Enum.any?(WardrikOAuth.Provider.all(oauth), &(&1.name == name)) ->
        taken("#{name} names an account this deployment offers")

      true ->
        :ok
    end
  end

  defp taken(why), do: {:error, Error.new(:conflict, why <> "; give it another name.")}

  defp serves?(server, owner), do: Enum.any?(server.serves, &Prefix.covers?(&1, owner))

  defp kept(%__MODULE__{store: store}, %Remote{key: key} = remote) do
    case Remote.put(store, remote) do
      :ok ->
        :ok

      {:error, :conflict} ->
        {:error, Error.new(:conflict, "#{key.owner} has a server named #{key.name} already.")}
    end
  end

  # One its owner signs in to starts the sign-in, and answers where; one
  # whose sign-in cannot start is not kept.
  defp signed_in(servers, remote, by) do
    case Remote.provider(remote) do
      {:ok, provider} -> started(servers, remote, provider, by)
      :none -> {:ok, :connected}
    end
  end

  defp started(servers, remote, provider, by) do
    holder = holder(remote.key.owner)

    case WardrikOAuth.hold(servers.oauth, provider, holder, vault: servers.vault, by: by) do
      {:ok, _credential} ->
        {:ok, :connected}

      {:error, {:authorization_required, link, _owner}} ->
        {:ok, link}

      {:error, reason} ->
        :ok = Remote.delete(servers.store, remote.key)

        {:error,
         Error.new(:unavailable, "#{remote.url} could not start a sign-in: #{inspect(reason)}")}
    end
  end

  # Its token, for a server its owner signed in to.
  defp forget(%__MODULE__{vault: vault}, remote) do
    with {:ok, provider} <- Remote.provider(remote),
         do: WardrikOAuth.disconnect(vault, provider.name, holder(remote.key.owner))

    :ok
  end

  # Whom the vault keeps an owner's credentials for: a person, or an org.
  defp holder(owner) do
    case Prefix.user(owner) do
      nil -> Prefix.org(owner)
      user -> {Prefix.org(owner), user}
    end
  end

  defimpl Wardrik.Servers do
    defdelegate list(servers, owner), to: WardrikMCP.Servers
    defdelegate add(servers, owner, opts), to: WardrikMCP.Servers
    defdelegate remove(servers, owner, opts), to: WardrikMCP.Servers
  end
end
