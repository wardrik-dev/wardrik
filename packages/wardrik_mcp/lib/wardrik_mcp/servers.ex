defmodule WardrikMCP.Servers do
  @moduledoc """
  The `Wardrik.Servers` orgs and people add MCP servers through, kept in
  `:store` as `WardrikMCP.Remote`s and reached by each node's
  `WardrikMCP.Remotes`:

      Wardrik.Host.new(store: store, servers: %WardrikMCP.Servers{store: store})

  A server's URL is held to `:check` as it is added, and again as each
  node starts its connection: an `https` URL whose host has public
  addresses alone, as `WardrikMCP.Remote.reachable/1` checks, unless it says.
  An owner's server may not take the name a server of the deployment's own
  that serves them already prefixes its tools with, since their tools would
  be named alike. Removing one stops every connection to it, on every node.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Servers.Key
  alias Wardrik.Servers.Listed
  alias WardrikMCP.Auth
  alias WardrikMCP.Remote

  @enforce_keys [:store]
  defstruct [:store, check: &Remote.reachable/1]

  @type t() :: %__MODULE__{
          store: WardrikStore.t(),
          check: (String.t() -> :ok | {:error, term()})
        }

  @doc false
  @spec list(t(), Prefix.t()) :: [Listed.t()]
  def list(%__MODULE__{store: store}, owner) do
    for remote <- Remote.list(store, owner),
        do: %Listed{name: remote.key.name, url: remote.url, auth: Auth.name(remote.auth)}
  end

  @doc false
  @spec add(t(), Prefix.t(), keyword()) :: {:ok, :connected} | {:error, Error.t()}
  def add(%__MODULE__{} = servers, owner, opts) do
    key = Key.new(owner, Keyword.fetch!(opts, :name))

    with {:ok, remote} <- decoded(key, Keyword.fetch!(opts, :fields)),
         :ok <- reachable(servers, remote),
         :ok <- unclaimed(key),
         :ok <- kept(servers, remote) do
      {:ok, :connected}
    end
  end

  @doc false
  @spec remove(t(), Prefix.t(), keyword()) :: :ok | {:error, Error.t()}
  def remove(%__MODULE__{store: store}, owner, opts) do
    key = Key.new(owner, Keyword.fetch!(opts, :name))

    case Remote.delete(store, key) do
      :ok ->
        :erpc.multicast(Node.list(), WardrikMCP, :close, [key])
        WardrikMCP.close(key)

      {:error, :not_found} ->
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
  # with its prefix, and so would the owner's of that name.
  defp unclaimed(%Key{owner: owner, name: name}) do
    if Enum.any?(WardrikMCP.Supervisor.servers(), &(&1.prefix == name and serves?(&1, owner))),
      do:
        {:error,
         Error.new(
           :conflict,
           "#{name} names a server this deployment offers #{owner}; give it another name."
         )},
      else: :ok
  end

  defp serves?(server, owner), do: Enum.any?(server.serves, &Prefix.covers?(&1, owner))

  defp kept(%__MODULE__{store: store}, %Remote{key: key} = remote) do
    case Remote.put(store, remote) do
      :ok ->
        :ok

      {:error, :conflict} ->
        {:error, Error.new(:conflict, "#{key.owner} has a server named #{key.name} already.")}
    end
  end

  defimpl Wardrik.Servers do
    defdelegate list(servers, owner), to: WardrikMCP.Servers
    defdelegate add(servers, owner, opts), to: WardrikMCP.Servers
    defdelegate remove(servers, owner, opts), to: WardrikMCP.Servers
  end
end
