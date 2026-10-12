defmodule WardrikStore do
  @moduledoc """
  The durable key-value store core and its packages write to, behind an
  adapter.

  Agent state, ledger claims and sealed credentials all land here. A
  deployment names the adapter once, as `Wardrik`'s `:store`, and everything
  that stores anything goes through this module:

      {Wardrik, store: [adapter: WardrikStore.EKV, data_dir: "/var/lib/wardrik"]}

  | Adapter | Keeps it |
  | --- | --- |
  | `WardrikStore.EKV` | on each node's disk, replicated between nodes. The default, where the application has `:ekv` |
  | `WardrikEcto.Store` | in a Postgres table, through an Ecto repo the host owns, where it has `:ecto_sql` and `:postgrex` |
  | `WardrikS3.Store` | in an S3 bucket |
  | `WardrikStore.Memory` | in one process, for tests |

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

  ## Starting it

  `Wardrik` starts the store before its fleet. A store
  kept through a host's repo starts after it, so the host starts `Wardrik` in
  its own tree; see `Wardrik`. A host that runs no fleet puts `WardrikStore`
  in its own tree instead, with the same settings:

      children = [MyApp.Repo, {WardrikStore, adapter: WardrikEcto.Store, repo: MyApp.Repo}]

  The settings are kept in `:persistent_term` as the store starts, and every
  read and write finds the adapter there; see `configure/1`.

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

  @default_adapter WardrikStore.EKV
  @settings {__MODULE__, :settings}

  @doc """
  Keeps `settings`, the adapter under `:adapter` and its options, as the
  store's: every read and write, `adapter/0` and `config/0` find them from
  then on. Answers `:ignore`, so a supervisor runs it as a child that starts
  nothing: `Wardrik` runs one first, before what its `:cluster` names, which
  may ask the store's quorum.
  """
  @spec configure(keyword()) :: :ignore
  def configure(settings) when is_list(settings) do
    :persistent_term.put(@settings, split(settings))
    :ignore
  end

  @doc "The adapter the store was started with, `WardrikStore.EKV` where none was named."
  @spec adapter() :: module()
  def adapter, do: elem(kept(), 0)

  @doc "The adapter's options, as the store was started with them."
  @spec config() :: keyword()
  def config, do: elem(kept(), 1)

  defp kept, do: :persistent_term.get(@settings)

  defp settings do
    {adapter, opts} = kept()
    [{:adapter, adapter} | opts]
  end

  defp split(settings), do: Keyword.pop(settings, :adapter, @default_adapter)

  @doc """
  The child that runs the adapter `settings` name, with its options, and
  keeps them as the store's as it starts. Raises where the adapter is not a
  module this node has, as one over a dependency the application leaves out
  is not.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(settings) when is_list(settings) do
    {adapter, opts} = split(settings)
    if message = missing(adapter), do: raise(ArgumentError, message)

    spec =
      case adapter.child_spec(opts) do
        nil -> %{start: {Function, :identity, [:ignore]}}
        spec -> Supervisor.child_spec(spec, [])
      end

    Map.merge(spec, %{id: __MODULE__, start: {__MODULE__, :start_link, [settings, spec.start]}})
  end

  @doc false
  @spec start_link(keyword(), {module(), atom(), [term()]}) :: GenServer.on_start()
  def start_link(settings, {module, function, args}) do
    :ignore = configure(settings)
    apply(module, function, args)
  end

  @doc """
  What the adapter `settings` name finds, as `c:check/1` answers. `settings`
  are the store's own by default.
  """
  @spec check(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def check(settings \\ settings()) do
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

  @doc "How many nodes of a cluster of `size` the store's adapter needs connected. See `c:quorum/1`."
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
  What agents are written through by `DurableServer`, for the adapter
  `settings` name: the store's own by default.

  Raises for an adapter without one, since a fleet cannot run without it.
  """
  @spec durable_backend(keyword()) :: {module(), keyword()}
  def durable_backend(settings \\ settings()) do
    {adapter, opts} = split(settings)

    if function_exported?(adapter, :durable_backend, 1) do
      adapter.durable_backend(opts)
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
