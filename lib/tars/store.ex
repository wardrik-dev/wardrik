defmodule Tars.Store do
  @moduledoc """
  The durable key-value store core and its packages write to, behind an
  adapter.

  Agent state, ledger claims and sealed credentials all land here. A
  deployment names the adapter once and everything that stores anything goes
  through this module:

      config :tars, Tars.Store, adapter: Tars.Store.EKV, data_dir: "/var/lib/tars"

  Core ships `Tars.Store.EKV`, the default, and `Tars.Store.Memory` for tests.
  An adapter over another system implements this behaviour and passes
  `Tars.Store.Conformance`.

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

  `Tars.Fleet.Supervisor` starts the store. A host that runs no fleet puts
  `Tars.Store` in its own tree instead.
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
    * `:ttl_ms` - how long the value lives
  """
  @type put_opts() :: [if_vsn: vsn() | nil, ttl_ms: pos_integer()]

  @typedoc "Options a read takes. `:consistent` reads through consensus where the adapter has one."
  @type get_opts() :: [consistent: boolean()]

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

  @optional_callbacks durable_backend: 1

  @default_adapter Tars.Store.EKV

  @doc "The adapter this deployment configured, `Tars.Store.EKV` by default."
  @spec adapter() :: module()
  def adapter, do: Keyword.get(config(), :adapter, @default_adapter)

  @doc "The adapter's options, as configured under `config :tars, Tars.Store`."
  @spec config() :: keyword()
  def config, do: :tars |> Application.get_env(__MODULE__, []) |> Keyword.delete(:adapter)

  @doc "The child that runs the configured adapter, with `opts` over its configuration."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    case adapter().child_spec(Keyword.merge(config(), opts)) do
      nil -> %{id: __MODULE__, start: {Function, :identity, [:ignore]}}
      spec -> Map.put(spec, :id, __MODULE__)
    end
  end

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
