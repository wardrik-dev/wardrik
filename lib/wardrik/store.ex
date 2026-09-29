defmodule Wardrik.Store do
  @moduledoc """
  The durable key-value store core and its packages write to, behind an
  adapter.

  Agent state, ledger claims and sealed credentials all land here. A
  deployment names the adapter once and everything that stores anything goes
  through this module:

      config :wardrik, Wardrik.Store, adapter: Wardrik.Store.EKV, data_dir: "/var/lib/wardrik"

  | Adapter | Keeps it |
  | --- | --- |
  | `Wardrik.Store.EKV` | on each node's disk, replicated between nodes. The default |
  | `WardrikEcto.Store` | in a Postgres table, through an Ecto repo the host owns |
  | `WardrikS3.Store` | in an S3 bucket |
  | `Wardrik.Store.Memory` | in one process, for tests |

  An adapter over another system implements this behaviour and passes
  `Wardrik.Store.Conformance`. One whose reads are current on every node can
  hold the fleet through `Wardrik.Store.Durable`.

  ## Namespaces

  Every key sits in a namespace, an atom the adapter maps to a prefix or a
  table. Core uses `:agents` and `:claims`; a package uses one of its own.
  Two callers never share a namespace, so neither has to know the other's keys.

  ## Versions

  A write may be conditional. `if_vsn: nil` writes only where nothing is
  written yet, and `if_vsn: vsn` writes only over the version `lookup/2`
  reported. Either answers `{:error, :conflict}` where the condition fails.
  An unconditional write answers `{:ok, nil}` on an adapter that does not
  version it.

  ## Starting it

  `Wardrik.Fleet.Supervisor` starts the store, as `Wardrik` starts. A store
  kept through a host's repo starts after it, so the host starts `Wardrik` in
  its own tree; see `Wardrik`. A host that runs no fleet puts `Wardrik.Store`
  in its own tree instead.

  `check/1` looks at a store without starting it, for `wardrik doctor`.
  """

  @typedoc "Which set of keys a value belongs to."
  @type ns() :: atom()

  @typedoc "A key within a namespace."
  @type key() :: String.t()

  @typedoc "What an adapter stamps a write with. Opaque."
  @type vsn() :: term()

  @typedoc """
  Options a write takes.

    * `:if_vsn` - write only where the current version is this one, with `nil`
      meaning where nothing is written
  """
  @type put_opts() :: [if_vsn: vsn() | nil]

  @typedoc """
  Options a read takes.

    * `:consistent` - read through consensus where the adapter has one
    * `:timeout` - how long, in milliseconds, a consistent read may wait
  """
  @type get_opts() :: [consistent: boolean(), timeout: pos_integer()]

  @typedoc "Options a delete takes. `:if_vsn` deletes only the version `lookup/2` reported."
  @type delete_opts() :: [if_vsn: vsn()]

  @doc "The child that runs this adapter, or `nil` for one that runs elsewhere."
  @callback child_spec(keyword()) :: Supervisor.child_spec() | nil

  @doc "Writes a value, conditionally where `opts` say so."
  @callback put(ns(), key(), term(), put_opts()) ::
              {:ok, vsn() | nil} | {:error, :conflict | term()}

  @doc "The value under a key, or `nil`."
  @callback get(ns(), key(), get_opts()) :: term() | nil

  @doc "The value under a key with its version, or `nil`."
  @callback lookup(ns(), key()) :: {term(), vsn()} | nil

  @doc "Removes a key. Removing one that is not there is `:ok`."
  @callback delete(ns(), key(), delete_opts()) :: :ok | {:error, :conflict | term()}

  @doc "Every key in a namespace starting with `prefix`."
  @callback keys(ns(), prefix :: String.t()) :: [key()]

  @doc "The `DurableServer` backend agents are written through, for an adapter that has one."
  @callback durable_backend(keyword()) :: {module(), keyword()}

  @doc """
  Looks at the store `opts` describe without starting it, and answers what it
  found, naming the store: that it is there and keeps the contract, or why not.
  """
  @callback check(keyword()) :: {:ok, String.t()} | {:error, String.t()}

  @doc """
  How many nodes of a cluster of `size`, this one among them, must be
  connected for a write to land: more than half for a store kept on the nodes
  themselves, and one for a store kept elsewhere.
  """
  @callback quorum(size :: pos_integer()) :: pos_integer()

  @optional_callbacks durable_backend: 1

  @default_adapter Wardrik.Store.EKV

  @doc "The adapter this deployment configured, `Wardrik.Store.EKV` by default."
  @spec adapter() :: module()
  def adapter, do: settings() |> split() |> elem(0)

  @doc "The adapter's options, as configured under `config :wardrik, Wardrik.Store`."
  @spec config() :: keyword()
  def config, do: settings() |> split() |> elem(1)

  defp settings, do: Application.get_env(:wardrik, __MODULE__, [])
  defp split(settings), do: Keyword.pop(settings, :adapter, @default_adapter)

  @doc "The child that runs the configured adapter, with `opts` over its configuration."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    case adapter().child_spec(Keyword.merge(config(), opts)) do
      nil -> %{id: __MODULE__, start: {Function, :identity, [:ignore]}}
      spec -> Map.put(spec, :id, __MODULE__)
    end
  end

  @doc """
  What the adapter `settings` name finds, as `c:check/1` answers. `settings`
  are as `config :wardrik, Wardrik.Store` holds them, which they are by default.
  """
  @spec check(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def check(settings \\ settings()) do
    {adapter, opts} = split(settings)
    adapter.check(opts)
  end

  @doc "How many nodes of a cluster of `size` the configured adapter needs connected. See `c:quorum/1`."
  @spec quorum(pos_integer()) :: pos_integer()
  def quorum(size) when is_integer(size) and size > 0, do: adapter().quorum(size)

  @doc """
  How long a `DurableServer.Supervisor` over the store gives its processes to
  write down their state as it stops: five seconds each, and ten in all. A
  store that answers takes milliseconds, and one whose node has lost its
  quorum does not answer however long it is given.
  """
  @spec durable_shutdown() :: keyword()
  def durable_shutdown,
    do: [graceful_shutdown_timeout_ms: 5_000, graceful_shutdown_total_timeout_ms: 10_000]

  @doc """
  The `DurableServer` backend of the configured adapter.

  Raises for an adapter without one, since a fleet cannot run without it.
  """
  @spec durable_backend(keyword()) :: {module(), keyword()}
  def durable_backend(opts \\ []) do
    adapter = adapter()

    if function_exported?(adapter, :durable_backend, 1) do
      adapter.durable_backend(Keyword.merge(config(), opts))
    else
      raise ArgumentError,
            "#{inspect(adapter)} provides no DurableServer backend, so it cannot hold a fleet"
    end
  end

  @spec put(ns(), key(), term(), put_opts()) :: {:ok, vsn() | nil} | {:error, :conflict | term()}
  def put(ns, key, value, opts \\ []) when is_atom(ns) and is_binary(key) do
    adapter().put(ns, key, value, opts)
  end

  @spec get(ns(), key(), get_opts()) :: term() | nil
  def get(ns, key, opts \\ []) when is_atom(ns) and is_binary(key),
    do: adapter().get(ns, key, opts)

  @spec lookup(ns(), key()) :: {term(), vsn()} | nil
  def lookup(ns, key) when is_atom(ns) and is_binary(key), do: adapter().lookup(ns, key)

  @doc """
  Removes `key`. With `if_vsn: vsn` it removes only that version, answering
  `{:error, :conflict}` where the key has been written since. A key written
  conditionally is deleted conditionally: an adapter may refuse otherwise.
  Deleting a key nothing holds is `:ok`.
  """
  @spec delete(ns(), key(), delete_opts()) :: :ok | {:error, :conflict | term()}
  def delete(ns, key, opts \\ []) when is_atom(ns) and is_binary(key),
    do: adapter().delete(ns, key, opts)

  @spec keys(ns(), String.t()) :: [key()]
  def keys(ns, prefix \\ "") when is_atom(ns) and is_binary(prefix),
    do: adapter().keys(ns, prefix)
end
