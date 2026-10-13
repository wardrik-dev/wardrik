defmodule WardrikStore.None do
  @moduledoc """
  The store of a host that names none: it starts nothing, and every read and
  write raises, saying so. `Wardrik.Host` holds it until a host names a
  store, so work that keeps nothing runs without one, and work that keeps
  something fails where it first tries.
  """

  @behaviour WardrikStore

  defstruct []

  @type t() :: %__MODULE__{}

  @impl WardrikStore
  def build(_opts), do: {:ok, %__MODULE__{}}

  defimpl WardrikStore.Adapter do
    # Every read and write raises, which is all they do.
    @dialyzer {:no_return, durable_backend: 1, put: 5, get: 4, lookup: 3, delete: 4, keys: 3}

    def child_spec(%WardrikStore.None{}),
      do: %{id: WardrikStore.None, start: {Function, :identity, [:ignore]}}

    def check(_store), do: {:error, "no store is named"}
    def quorum(_store, _size), do: 1
    def durable_backend(_store), do: unnamed()
    def put(_store, _ns, _key, _value, _opts), do: unnamed()
    def get(_store, _ns, _key, _opts), do: unnamed()
    def lookup(_store, _ns, _key), do: unnamed()
    def delete(_store, _ns, _key, _opts), do: unnamed()
    def keys(_store, _ns, _prefix), do: unnamed()

    defp unnamed, do: raise(ArgumentError, "the host names no store; see Wardrik.Host")
  end
end
