defmodule WardrikStore do
  @moduledoc """
  The durable key-value store core and its packages write to, behind an
  adapter.

  Agent state, ledger claims and sealed credentials all land here. A
  deployment names the adapter once, and everything that stores anything
  goes through this module, handed the store that names:

      store = WardrikStore.new(adapter: WardrikStore.EKV, data_dir: "/var/lib/wardrik")

  | Adapter | Keeps it |
  | --- | --- |
  | `WardrikStore.EKV` | on each node's disk, replicated between nodes. The default, where the application has `:ekv` |
  | `WardrikEcto.Store` | in a Postgres table, through an Ecto repo the host owns, where it has `:ecto_sql` and `:postgrex` |
  | `WardrikS3.Store` | in an S3 bucket |
  | `WardrikStore.Memory` | in one process, for tests |
  | `WardrikStore.None` | nowhere: the store of a host that names none, whose every read and write raises |

  An adapter over another system implements this behaviour and passes
  `WardrikStore.Conformance`. One whose reads are current on every node can
  hold the fleet through `WardrikStore.Durable`.

  ## Namespaces

  Every key sits in a namespace, an atom the adapter maps to a prefix or a
  column: `wardrik/<namespace>/<key>` on EKV and in a bucket, and a row's `ns`
  in Postgres. Core keeps ledger claims in `:claims` and each agent's events in
  `:events`; a package uses one of its own, as `WardrikVault` does `:vault` and
  `WardrikHTTP` does `:tokens`. Two callers never share a namespace, so neither
  has to know the other's keys.

  The fleet is kept by `DurableServer`, whose supervisors each write under a
  prefix of their own: `agents/<key>` for agents, and, where triggers and
  budgets run, `triggers/` and `meters/`, with each node's heartbeat under
  `<prefix>__nodes/`. Through `WardrikStore.Durable` they sit in the
  `:durable` namespace, so an agent in a bucket is
  `wardrik/durable/agents/acme/@jon/triage`. On EKV, DurableServer's own backend
  writes them beside the namespaces, as `agents/acme/@jon/triage`.

  ## Versions

  A write may be conditional. `if_vsn: nil` writes only where nothing is
  written yet, and `if_vsn: vsn` writes only over the version `lookup/2`
  reported. Either answers `{:error, :conflict}` where the condition fails.
  An unconditional write answers `{:ok, nil}` on an adapter that does not
  version it.

  ## The store as a value

  A store is a value, `t:t/0`: the adapter and what its calls need, made
  once from the deployment's settings by `new/1`, and handed to whatever
  reads or writes. Nothing of it is kept where a node finds it, so two
  stores on one node are two values:

      store = WardrikStore.new(adapter: WardrikStore.EKV, data_dir: "/var/lib/wardrik")
      {:ok, _vsn} = WardrikStore.put(store, :mine, "a", 1)
      WardrikStore.get(store, :mine, "a")
      #=> 1

  ## Starting it

  A host starts the store, then hands the same value to `Wardrik` on its
  `Wardrik.Host`, and to whatever else it starts that stores anything. A
  store kept through a host's repo starts after it:

      store = WardrikStore.new(adapter: WardrikEcto.Store, repo: MyApp.Repo)
      host = Wardrik.Host.new(store: store)

      children = [MyApp.Repo, {WardrikStore, store}, {Wardrik, host: host}]

  `check/1` looks at a store without starting it, for `wardrik doctor`.
  """

  # What an adapter's calls are handed may hold its credentials, as a
  # bucket's keys, so a store is shown by its adapter alone.
  @derive {Inspect, only: [:adapter]}
  @enforce_keys [:adapter, :config]
  defstruct [:adapter, :config]

  @typedoc "A store: its adapter, and what the adapter's calls are handed."
  @type t() :: %__MODULE__{adapter: module(), config: term()}

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

  @doc """
  What the adapter's calls are handed, from the options a deployment names
  it with. Made without starting anything; raises where the options cannot
  describe a store.
  """
  @callback config(keyword()) :: term()

  @doc "The child that runs the store `config` describes."
  @callback child_spec(config :: term()) :: Supervisor.child_spec()

  @doc "Writes a value, conditionally where `opts` say so."
  @callback put(config :: term(), ns(), key(), term(), put_opts()) ::
              {:ok, vsn() | nil} | {:error, :conflict | term()}

  @doc "The value under a key, or `nil`."
  @callback get(config :: term(), ns(), key(), get_opts()) :: term() | nil

  @doc "The value under a key with its version, or `nil`."
  @callback lookup(config :: term(), ns(), key()) :: {term(), vsn()} | nil

  @doc "Removes a key. Removing one that is not there is `:ok`."
  @callback delete(config :: term(), ns(), key(), delete_opts()) ::
              :ok | {:error, :conflict | term()}

  @doc "Every key in a namespace starting with `prefix`."
  @callback keys(config :: term(), ns(), prefix :: String.t()) :: [key()]

  @doc "The `DurableServer` backend agents are written through."
  @callback durable_backend(t()) :: {module(), keyword()}

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

  @default_adapter WardrikStore.EKV

  @doc """
  The store `settings` describe: the adapter under `:adapter`,
  `WardrikStore.EKV` where none is named, and its options. Starts nothing.
  Raises where the adapter is not a module this node has, as one over a
  dependency the application leaves out is not.
  """
  @spec new(keyword()) :: t()
  def new(settings \\ []) when is_list(settings) do
    {adapter, opts} = split(settings)
    if message = missing(adapter), do: raise(ArgumentError, message)
    %__MODULE__{adapter: adapter, config: adapter.config(opts)}
  end

  defp split(settings), do: Keyword.pop(settings, :adapter, @default_adapter)

  @doc "The child that runs `store`."
  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{adapter: adapter, config: config}),
    do: Supervisor.child_spec(adapter.child_spec(config), id: __MODULE__)

  @doc """
  What the adapter `settings` name finds, as `c:check/1` answers, without
  starting it.
  """
  @spec check(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def check(settings) when is_list(settings) do
    {adapter, opts} = split(settings)

    case missing(adapter) do
      nil -> adapter.check(opts)
      message -> {:error, message}
    end
  end

  # The adapters over optional dependencies are compiled only where the
  # application has them, so a host that stores elsewhere compiles neither.
  defp missing(adapter) do
    unless Code.ensure_loaded?(adapter) do
      "#{inspect(adapter)} is not a module this node has. WardrikEcto.Store needs " <>
        ":ecto_sql and :postgrex among the application's dependencies, and " <>
        "WardrikStore.EKV, the store where no adapter is named, needs :ekv"
    end
  end

  @doc "How many nodes of a cluster of `size` `store` needs connected. See `c:quorum/1`."
  @spec quorum(t(), pos_integer()) :: pos_integer()
  def quorum(%__MODULE__{adapter: adapter}, size) when is_integer(size) and size > 0,
    do: adapter.quorum(size)

  @doc """
  How long a `DurableServer.Supervisor` over the store gives its processes to
  write down their state as it stops: five seconds each, and ten in all. A
  store that answers takes milliseconds, and one whose node has lost its
  quorum does not answer however long it is given.
  """
  @spec durable_shutdown() :: keyword()
  def durable_shutdown,
    do: [graceful_shutdown_timeout_ms: 5_000, graceful_shutdown_total_timeout_ms: 10_000]

  @doc "What `DurableServer` writes agents through in `store`."
  @spec durable_backend(t()) :: {module(), keyword()}
  def durable_backend(%__MODULE__{adapter: adapter} = store), do: adapter.durable_backend(store)

  @spec put(t(), ns(), key(), term(), put_opts()) ::
          {:ok, vsn() | nil} | {:error, :conflict | term()}
  def put(%__MODULE__{} = store, ns, key, value, opts \\ []) when is_atom(ns) and is_binary(key),
    do: store.adapter.put(store.config, ns, key, value, opts)

  @spec get(t(), ns(), key(), get_opts()) :: term() | nil
  def get(%__MODULE__{} = store, ns, key, opts \\ []) when is_atom(ns) and is_binary(key),
    do: store.adapter.get(store.config, ns, key, opts)

  @spec lookup(t(), ns(), key()) :: {term(), vsn()} | nil
  def lookup(%__MODULE__{} = store, ns, key) when is_atom(ns) and is_binary(key),
    do: store.adapter.lookup(store.config, ns, key)

  @doc """
  Removes `key`. With `if_vsn: vsn` it removes only that version, answering
  `{:error, :conflict}` where the key has been written since. A key written
  conditionally is deleted conditionally: an adapter may refuse otherwise.
  Deleting a key nothing holds is `:ok`.
  """
  @spec delete(t(), ns(), key(), delete_opts()) :: :ok | {:error, :conflict | term()}
  def delete(%__MODULE__{} = store, ns, key, opts \\ []) when is_atom(ns) and is_binary(key),
    do: store.adapter.delete(store.config, ns, key, opts)

  @spec keys(t(), ns(), String.t()) :: [key()]
  def keys(%__MODULE__{} = store, ns, prefix \\ "") when is_atom(ns) and is_binary(prefix),
    do: store.adapter.keys(store.config, ns, prefix)
end
