defmodule WardrikStore do
  @moduledoc """
  A durable key-value store. Wardrik packages keep their data in it, each under its own scope.

      store = WardrikStore.ETS.new(name: MyApp.Store)
      children = [{WardrikStore, store}]

      mine = WardrikStore.scope(store, "my_app")
      {:ok, vsn} = WardrikStore.put(mine, "settings/theme", "dark", if_vsn: nil)

  The adapter decides where keys are kept. See `WardrikStore.ETS`, `WardrikStore.EKV` and
  `WardrikStore.Ecto`.
  """

  alias WardrikStore.Adapter

  @enforce_keys [:adapter, :config]
  defstruct [:adapter, :config, scope: ""]

  @typedoc "A store, scoped or not."
  @type t() :: %__MODULE__{adapter: module(), config: Adapter.config(), scope: String.t()}

  @typedoc "A key within a scope."
  @type key() :: String.t()

  @typedoc "The version an adapter stamps a write with."
  @type vsn() :: term()

  @scope_name ~r/^[a-z][a-z0-9_]*$/

  @doc "Builds a store over `adapter`. Adapters call this from their own `new/1`."
  @spec new(module(), Adapter.config()) :: t()
  def new(adapter, config) when is_atom(adapter),
    do: %__MODULE__{adapter: adapter, config: config}

  @doc """
  Returns the child spec that runs the store. Starts nothing if it's already running.

      children = [{WardrikStore, store}]
  """
  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{adapter: adapter, config: config}) do
    %{start: start} = spec = adapter.child_spec(config)
    Supervisor.child_spec(%{spec | start: {__MODULE__, :start_once, [start]}}, id: __MODULE__)
  end

  @doc false
  @spec start_once({module(), atom(), [term()]}) :: Supervisor.on_start_child()
  def start_once({module, function, args}) do
    case apply(module, function, args) do
      {:error, {:already_started, _pid}} -> :ignore
      started -> started
    end
  end

  @doc """
  Returns the store nested under the scope `name`. Keys in one scope never match another's.

      mine = WardrikStore.scope(store, "my_app")

  `name` is lowercase letters, digits and underscores, starting with a letter. Raises
  `ArgumentError` otherwise.
  """
  @spec scope(t(), String.t()) :: t()
  def scope(%__MODULE__{} = store, name) when is_binary(name) do
    if Regex.match?(@scope_name, name),
      do: %{store | scope: nested(store.scope, name)},
      else: raise(ArgumentError, not_a_scope_name(name))
  end

  @doc """
  Writes `value` under `key`. Returns `{:ok, vsn}`.

      {:ok, vsn} = WardrikStore.put(store, "settings/theme", "dark", if_vsn: nil)
      {:ok, _vsn} = WardrikStore.put(store, "settings/theme", "light", if_vsn: vsn)
      {:error, :conflict} = WardrikStore.put(store, "settings/theme", "blue", if_vsn: vsn)

  ## Options

    * `:if_vsn` - writes only over this version, or only where `key` is empty when `nil`.
      Returns `{:error, :conflict}` otherwise. Without it, some adapters return `{:ok, nil}`.
  """
  @spec put(t(), key(), term(), if_vsn: vsn() | nil) ::
          {:ok, vsn() | nil} | {:error, :conflict | term()}
  def put(%__MODULE__{} = store, key, value, opts \\ []) when is_binary(key),
    do: store.adapter.put(store.config, path(store, key), value, opts)

  @doc "Returns the value under `key`, or `nil`."
  @spec get(t(), key()) :: term() | nil
  def get(%__MODULE__{} = store, key) do
    case lookup(store, key) do
      {value, _vsn} -> value
      nil -> nil
    end
  end

  @doc "Returns `{value, vsn}` for `key`, or `nil`."
  @spec lookup(t(), key()) :: {term(), vsn()} | nil
  def lookup(%__MODULE__{} = store, key) when is_binary(key),
    do: store.adapter.lookup(store.config, path(store, key))

  @doc """
  Removes `key`. Returns `:ok`, also when `key` isn't there.

  ## Options

    * `:if_vsn` - removes only this version. Returns `{:error, :conflict}` otherwise.
  """
  @spec delete(t(), key(), if_vsn: vsn()) :: :ok | {:error, :conflict | term()}
  def delete(%__MODULE__{} = store, key, opts \\ []) when is_binary(key),
    do: store.adapter.delete(store.config, path(store, key), opts)

  @doc "Returns the scope's keys that start with `prefix`, sorted."
  @spec keys(t(), String.t()) :: [key()]
  def keys(%__MODULE__{} = store, prefix \\ "") when is_binary(prefix) do
    root = path(store, "")
    paths = store.adapter.keys(store.config, root <> prefix)

    paths
    |> Enum.map(&String.replace_prefix(&1, root, ""))
    |> Enum.sort()
  end

  @doc "Returns `%{key => {value, vsn}}` for `keys`. Keys that aren't there are left out."
  @spec lookup_many(t(), [key()]) :: %{key() => {term(), vsn()}}
  def lookup_many(%__MODULE__{} = store, keys) when is_list(keys) do
    paths = Map.new(keys, &{path(store, &1), &1})

    for {path, value, vsn} <- many(store, Map.keys(paths)),
        into: %{},
        do: {Map.fetch!(paths, path), {value, vsn}}
  end

  @doc "Returns `{key, value, vsn}` for each of the scope's keys that starts with `prefix`, sorted by key."
  @spec entries(t(), String.t()) :: [{key(), term(), vsn()}]
  def entries(%__MODULE__{} = store, prefix \\ "") when is_binary(prefix) do
    root = path(store, "")

    store
    |> listed(root <> prefix)
    |> Enum.map(fn {path, value, vsn} -> {String.replace_prefix(path, root, ""), value, vsn} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp many(%__MODULE__{adapter: adapter, config: config}, paths) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :lookup_many, 2),
      do: adapter.lookup_many(config, paths),
      else: one_by_one(adapter, config, paths)
  end

  defp listed(%__MODULE__{adapter: adapter, config: config}, prefix) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :entries, 2),
      do: adapter.entries(config, prefix),
      else: one_by_one(adapter, config, adapter.keys(config, prefix))
  end

  defp one_by_one(adapter, config, paths) do
    for path <- paths, {value, vsn} <- [adapter.lookup(config, path)], do: {path, value, vsn}
  end

  defp nested("", name), do: name
  defp nested(scope, name), do: scope <> "/" <> name

  defp path(%__MODULE__{scope: scope}, key), do: scope <> ":" <> key

  defp not_a_scope_name(name),
    do: "A scope's name is lowercase letters, digits and underscores, got: #{inspect(name)}"
end
