defmodule WardrikCore.Backends.Prefixed do
  @moduledoc """
  Lets supervisors on one node share a `DurableServer` prefix, each with a backend of its own.

  DurableServer lets one supervisor on a node hold a prefix, whatever its storage. `options/1`
  gives a supervisor a prefix named after it, and a backend that stores under the shared one.
  Stored keys don't name the supervisor.

      opts
      |> WardrikCore.Backends.Prefixed.options()
      |> DurableServer.Supervisor.child_spec()
  """

  @behaviour DurableServer.StorageBackend

  alias DurableServer.StorageBackend

  @doc "Returns `DurableServer.Supervisor` options, `:name`, `:prefix` and `:backend` required."
  @spec options(keyword()) :: keyword()
  def options(opts) do
    stored = Keyword.fetch!(opts, :prefix)

    name =
      opts
      |> Keyword.fetch!(:name)
      |> inspect()
      |> URI.encode_www_form()

    prefix = stored <> name <> "/"
    backend = %{backend: Keyword.fetch!(opts, :backend), from: prefix, to: stored}
    Keyword.merge(opts, prefix: prefix, backend: {__MODULE__, backend})
  end

  @impl StorageBackend
  def init_backend(%{backend: backend, from: from, to: to}) do
    with {:ok, inner} <- inner(backend) do
      # Pushed updates would name stored keys, which this backend doesn't map back.
      defaults =
        inner
        |> StorageBackend.defaults()
        |> Map.put(:heartbeat_tracking_mode, :poll)

      {:ok,
       %{
         state: %{inner: inner, from: from, to: to},
         defaults: defaults,
         features: StorageBackend.features(inner)
       }}
    end
  end

  defp inner(%StorageBackend{} = backend), do: {:ok, backend}
  defp inner({adapter, opts}), do: StorageBackend.init_backend(adapter, opts)

  @doc "Returns the key `key` is stored under."
  @spec stored(map(), String.t()) :: String.t()
  def stored(%{from: from, to: to}, key), do: to <> unprefixed(key, from)

  @impl StorageBackend
  def ensure_ready(state), do: StorageBackend.ensure_ready(state.inner)

  @impl StorageBackend
  def get_object(state, key, opts),
    do: StorageBackend.get_object(state.inner, stored(state, key), opts)

  @impl StorageBackend
  def list_all_objects_stream(state, prefix, opts) do
    state.inner
    |> StorageBackend.list_all_objects_stream(stored(state, prefix), opts)
    |> Stream.map(fn %{key: key} = object -> %{object | key: own(state, key)} end)
  end

  @impl StorageBackend
  def put_object(state, key, data, opts),
    do: StorageBackend.put_object(state.inner, stored(state, key), data, opts)

  @impl StorageBackend
  def delete_object(state, key), do: StorageBackend.delete_object(state.inner, stored(state, key))

  @impl StorageBackend
  def delete_object(state, key, opts),
    do: StorageBackend.delete_object(state.inner, stored(state, key), opts)

  @impl StorageBackend
  def try_claim(state, key, body),
    do: StorageBackend.try_claim(state.inner, stored(state, key), body)

  @impl StorageBackend
  def update_object(state, key, update, opts),
    do: StorageBackend.update_object(state.inner, stored(state, key), update, opts)

  @impl StorageBackend
  def encode(state, data), do: state.inner.adapter.encode(state.inner.state, data)

  @impl StorageBackend
  def decode(state, data), do: state.inner.adapter.decode(state.inner.state, data)

  defp own(%{from: from, to: to}, key), do: from <> unprefixed(key, to)

  defp unprefixed(key, prefix) do
    size = byte_size(prefix)
    <<^prefix::binary-size(^size), rest::binary>> = key
    rest
  end
end
