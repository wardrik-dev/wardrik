defmodule Wardrik.Store.Memory do
  @moduledoc """
  A `Wardrik.Store` in one process's memory, for tests and for a node that keeps
  nothing.

      config :wardrik, Wardrik.Store, adapter: Wardrik.Store.Memory

  Every write is versioned, so conditional writes behave as they do on a
  durable adapter. It provides no `DurableServer` backend, so it cannot hold a fleet.
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

  @impl Wardrik.Store
  def check(_opts), do: {:ok, "in this node's memory"}

  @impl Wardrik.Store
  def quorum(_size), do: 1

  @doc "Forgets everything."
  @spec clear() :: :ok
  def clear, do: Agent.update(__MODULE__, fn _state -> %{} end)

  @impl Wardrik.Store
  def put(ns, key, value, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      if conflict?(Keyword.fetch(opts, :if_vsn), Map.get(state, {ns, key})),
        do: {{:error, :conflict}, state},
        else: write(state, ns, key, value)
    end)
  end

  defp conflict?(:error, _current), do: false
  defp conflict?({:ok, nil}, nil), do: false
  defp conflict?({:ok, nil}, _current), do: true
  defp conflict?({:ok, _vsn}, nil), do: true
  defp conflict?({:ok, vsn}, {_value, vsn}), do: false
  defp conflict?({:ok, _vsn}, _current), do: true

  @impl Wardrik.Store
  def get(ns, key, _opts) do
    case lookup(ns, key) do
      {value, _vsn} -> value
      nil -> nil
    end
  end

  @impl Wardrik.Store
  def lookup(ns, key), do: Agent.get(__MODULE__, &Map.get(&1, {ns, key}))

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
    Agent.get(__MODULE__, fn state ->
      keys = for {{^ns, key}, _entry} <- state, String.starts_with?(key, prefix), do: key
      Enum.sort(keys)
    end)
  end

  defp write(state, ns, key, value) do
    vsn = System.unique_integer([:positive, :monotonic])
    {{:ok, vsn}, Map.put(state, {ns, key}, {value, vsn})}
  end
end
