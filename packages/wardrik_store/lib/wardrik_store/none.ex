defmodule WardrikStore.None do
  @moduledoc """
  The store of a host that names none: it starts nothing, and every read and
  write raises, saying so. `Wardrik.Host` holds it until a host names a
  store, so work that keeps nothing runs without one, and work that keeps
  something fails where it first tries.
  """

  @behaviour WardrikStore

  # Every read and write raises, which is all they do.
  @dialyzer {:no_return, durable_backend: 1, put: 5, get: 4, lookup: 3, delete: 4, keys: 3}

  @impl WardrikStore
  def config(_opts), do: :none

  @impl WardrikStore
  def child_spec(:none), do: %{id: __MODULE__, start: {Function, :identity, [:ignore]}}

  @impl WardrikStore
  def check(_opts), do: {:error, "no store is named"}

  @impl WardrikStore
  def quorum(_size), do: 1

  @impl WardrikStore
  def durable_backend(_store), do: unnamed()

  @impl WardrikStore
  def put(:none, _ns, _key, _value, _opts), do: unnamed()

  @impl WardrikStore
  def get(:none, _ns, _key, _opts), do: unnamed()

  @impl WardrikStore
  def lookup(:none, _ns, _key), do: unnamed()

  @impl WardrikStore
  def delete(:none, _ns, _key, _opts), do: unnamed()

  @impl WardrikStore
  def keys(:none, _ns, _prefix), do: unnamed()

  defp unnamed, do: raise(ArgumentError, "the host names no store; see Wardrik.Host")
end
