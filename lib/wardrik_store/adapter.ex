defmodule WardrikStore.Adapter do
  @moduledoc """
  Decides where a store keeps its keys. Callers use `WardrikStore`, not the adapter.

      defmodule MyApp.Store do
        @behaviour WardrikStore.Adapter

        def new(opts), do: WardrikStore.new(__MODULE__, Keyword.fetch!(opts, :name))

        # child_spec/1, put/4, lookup/2, delete/3 and keys/2 follow
      end

    * Each callback gets the config from `new/1`, and a full path with the store's scopes.
    * `c:lookup_many/2` and `c:entries/2` are optional. Implement them when batch reads are cheaper.
  """

  @typedoc "The config the adapter's `new/1` built. Each callback gets it."
  @type config() :: term()

  @doc "Returns the child that runs the adapter."
  @callback child_spec(config()) :: Supervisor.child_spec()

  @doc "Writes `value` under `path`. Takes `:if_vsn` as `WardrikStore.put/4` does."
  @callback put(config(), path :: String.t(), value :: term(), keyword()) ::
              {:ok, WardrikStore.vsn() | nil} | {:error, :conflict | term()}

  @doc "Returns `{value, vsn}` for `path`, or `nil`."
  @callback lookup(config(), path :: String.t()) :: {term(), WardrikStore.vsn()} | nil

  @doc "Removes `path`. Returns `:ok` if it isn't there. Takes `:if_vsn` as `WardrikStore.delete/3` does."
  @callback delete(config(), path :: String.t(), keyword()) :: :ok | {:error, :conflict | term()}

  @doc "Returns every path that starts with `prefix`."
  @callback keys(config(), prefix :: String.t()) :: [String.t()]

  @doc "Returns `{path, value, vsn}` for each of `paths`. Paths that aren't there are left out."
  @callback lookup_many(config(), paths :: [String.t()]) :: [
              {String.t(), term(), WardrikStore.vsn()}
            ]

  @doc "Returns `{path, value, vsn}` for every path that starts with `prefix`."
  @callback entries(config(), prefix :: String.t()) :: [{String.t(), term(), WardrikStore.vsn()}]

  @optional_callbacks lookup_many: 2, entries: 2
end
