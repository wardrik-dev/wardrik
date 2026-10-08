defmodule Wardrik.Store.Memory do
  @moduledoc """
  A `Wardrik.Store` in this node's memory, for tests and for a node that keeps
  nothing.

      config :wardrik, Wardrik.Store, adapter: Wardrik.Store.Memory

  Every write is versioned, so conditional writes behave as they do on a
  durable adapter. It holds the fleet of one node through
  `Wardrik.Store.Durable`, and keeps nothing past it, which is what a test
  suite wants: a package's tests boot Wardrik with no store to set up.

  Entries are kept in an ordered ETS table its process owns. Reads go to
  the table straight from the caller, and writes go through the process, one
  at a time, so a conditional write sees the version it is conditioned on.

  ## Instances

  `:name` starts another instance beside the one the adapter uses, for a
  test that wants a store of its own. Every function takes `name:` in its
  options to work on that instance:

      start_supervised!({Wardrik.Store.Memory, name: :mine})
      Wardrik.Store.Memory.put(:ns, "a", 1, name: :mine)
      Wardrik.Store.Memory.keys(:ns, "", name: :mine)
  """

  @behaviour Wardrik.Store

  use GenServer

  @doc "Starts the store, empty, under `:name`, the adapter's own unless given."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  @impl Wardrik.Store
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl Wardrik.Store
  def check(_opts), do: {:ok, "in this node's memory"}

  @impl Wardrik.Store
  def quorum(_size), do: 1

  # Its reads are current because there is only the one node.
  @impl Wardrik.Store
  def durable_backend(opts), do: {Wardrik.Store.Durable, [store: __MODULE__] ++ opts}

  @doc "Forgets everything."
  @spec clear(keyword()) :: :ok
  def clear(opts \\ []), do: GenServer.call(name(opts), :clear)

  @impl Wardrik.Store
  def put(ns, key, value, opts),
    do: GenServer.call(name(opts), {:put, {ns, key}, value, Keyword.fetch(opts, :if_vsn)})

  @impl Wardrik.Store
  def get(ns, key, opts) do
    case lookup(ns, key, opts) do
      {value, _vsn} -> value
      nil -> nil
    end
  end

  @impl Wardrik.Store
  def lookup(ns, key, opts \\ []) do
    case :ets.lookup(name(opts), {ns, key}) do
      [{_key, value, vsn}] -> {value, vsn}
      [] -> nil
    end
  end

  @impl Wardrik.Store
  def delete(ns, key, opts),
    do: GenServer.call(name(opts), {:delete, {ns, key}, Keyword.fetch(opts, :if_vsn)})

  @doc """
  Every key in `ns` starting with `prefix`, in order. The table is walked
  from the prefix to the first key past it, so no other key is read.
  """
  @impl Wardrik.Store
  def keys(ns, prefix, opts \\ []) do
    table = name(opts)
    from = {ns, prefix}
    first = if :ets.member(table, from), do: from, else: :ets.next(table, from)
    walk(table, first, ns, prefix, [])
  end

  defp walk(table, {ns, key} = at, ns, prefix, keys) do
    if String.starts_with?(key, prefix),
      do: walk(table, :ets.next(table, at), ns, prefix, [key | keys]),
      else: Enum.reverse(keys)
  end

  defp walk(_table, _past, _ns, _prefix, keys), do: Enum.reverse(keys)

  defp name(opts), do: Keyword.get(opts, :name, __MODULE__)

  @impl GenServer
  def init(name),
    do: {:ok, :ets.new(name, [:ordered_set, :protected, :named_table, read_concurrency: true])}

  @impl GenServer
  def handle_call({:put, key, value, if_vsn}, _from, table) do
    if conflict?(if_vsn, :ets.lookup(table, key)) do
      {:reply, {:error, :conflict}, table}
    else
      vsn = System.unique_integer([:positive, :monotonic])
      true = :ets.insert(table, {key, value, vsn})
      {:reply, {:ok, vsn}, table}
    end
  end

  def handle_call({:delete, key, if_vsn}, _from, table) do
    case {if_vsn, :ets.lookup(table, key)} do
      {{:ok, vsn}, [{_key, _value, current}]} when current != vsn ->
        {:reply, {:error, :conflict}, table}

      _unconditional_or_current ->
        true = :ets.delete(table, key)
        {:reply, :ok, table}
    end
  end

  def handle_call(:clear, _from, table) do
    true = :ets.delete_all_objects(table)
    {:reply, :ok, table}
  end

  defp conflict?(:error, _current), do: false
  defp conflict?({:ok, nil}, []), do: false
  defp conflict?({:ok, nil}, _current), do: true
  defp conflict?({:ok, _vsn}, []), do: true
  defp conflict?({:ok, vsn}, [{_key, _value, vsn}]), do: false
  defp conflict?({:ok, _vsn}, _current), do: true
end
