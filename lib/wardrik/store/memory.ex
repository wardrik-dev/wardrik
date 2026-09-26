defmodule Wardrik.Store.Memory do
  @moduledoc """
  A `Wardrik.Store` in one process's memory, for tests and for a node that keeps
  nothing.

      config :wardrik, Wardrik.Store, adapter: Wardrik.Store.Memory

  Every write is versioned, so conditional writes behave as they do on a
  durable adapter. Values with a `:ttl_ms` are gone once it has passed. It
  provides no `DurableServer` backend, so it cannot hold a fleet.
  """

  @behaviour Wardrik.Store

  use Agent

  @doc "Starts the store, empty."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @impl Wardrik.Store
  def child_spec(opts),
    do:
      Supervisor.child_spec({Agent, fn -> %{} end},
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      )

  @doc "Forgets everything."
  @spec clear() :: :ok
  def clear, do: Agent.update(__MODULE__, fn _state -> %{} end)

  @impl Wardrik.Store
  def put(ns, key, value, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = sweep(state)
      current = Map.get(state, {ns, key})

      if conflict?(Keyword.fetch(opts, :if_vsn), current),
        do: {{:error, :conflict}, state},
        else: write(state, ns, key, value, opts)
    end)
  end

  defp conflict?(:error, _current), do: false
  defp conflict?({:ok, nil}, nil), do: false
  defp conflict?({:ok, nil}, _current), do: true
  defp conflict?({:ok, _vsn}, nil), do: true
  defp conflict?({:ok, vsn}, {_value, vsn, _expires_at}), do: false
  defp conflict?({:ok, _vsn}, _current), do: true

  @impl Wardrik.Store
  def get(ns, key, _opts) do
    case lookup(ns, key) do
      {value, _vsn} -> value
      nil -> nil
    end
  end

  @impl Wardrik.Store
  def lookup(ns, key) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = sweep(state)

      case Map.get(state, {ns, key}) do
        {value, vsn, _expires_at} -> {{value, vsn}, state}
        nil -> {nil, state}
      end
    end)
  end

  @impl Wardrik.Store
  def delete(ns, key, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      current = Map.get(state, {ns, key})

      case Keyword.fetch(opts, :if_vsn) do
        {:ok, vsn} when current != nil and elem(current, 1) != vsn -> {{:error, :conflict}, state}
        _unconditional_or_current -> {:ok, Map.delete(state, {ns, key})}
      end
    end)
  end

  @impl Wardrik.Store
  def keys(ns, prefix) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = sweep(state)

      keys =
        for {{^ns, key}, _entry} <- state, String.starts_with?(key, prefix), do: key

      {Enum.sort(keys), state}
    end)
  end

  defp write(state, ns, key, value, opts) do
    vsn = System.unique_integer([:positive, :monotonic])
    expires_at = expiry(Keyword.get(opts, :ttl_ms))

    {{:ok, vsn}, Map.put(state, {ns, key}, {value, vsn, expires_at})}
  end

  defp expiry(nil), do: nil
  defp expiry(ms), do: System.monotonic_time(:millisecond) + ms

  defp sweep(state) do
    now = System.monotonic_time(:millisecond)

    Map.reject(state, fn
      {_key, {_value, _vsn, nil}} -> false
      {_key, {_value, _vsn, expires_at}} -> expires_at <= now
    end)
  end
end
