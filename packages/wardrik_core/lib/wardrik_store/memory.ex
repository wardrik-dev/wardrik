defmodule WardrikStore.Memory do
  @moduledoc """
  A `WardrikStore` in this node's memory, for tests and for a node that keeps
  nothing.

      store = WardrikStore.new(adapter: WardrikStore.Memory)

  Every write is versioned, so conditional writes behave as they do on a
  durable adapter. It holds the fleet of one node through
  `WardrikStore.Durable`, and keeps nothing past it, which is what a test
  suite wants: a package's tests boot Wardrik with no store to set up.

  Entries are kept in an ordered ETS table its process owns. Reads go to
  the table straight from the caller, and writes go through the process, one
  at a time, so a conditional write sees the version it is conditioned on.

  ## Instances

  `:name` names the instance, `WardrikStore.Memory` unless given, so a test
  that wants a store of its own starts one beside any other:

      store = WardrikStore.new(adapter: WardrikStore.Memory, name: :mine)
      start_supervised!({WardrikStore, store})
      WardrikStore.put(store, :ns, "a", 1)
  """

  @behaviour WardrikStore

  use GenServer

  @enforce_keys [:name]
  defstruct [:name]

  @typedoc "A store in memory: the name of its process and of the table it owns."
  @type t() :: %__MODULE__{name: atom()}

  @impl WardrikStore
  def build(opts), do: {:ok, %__MODULE__{name: Keyword.get(opts, :name, __MODULE__)}}

  @doc "Starts the store, empty, under `name`."
  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name) when is_atom(name), do: GenServer.start_link(__MODULE__, name, name: name)

  @doc "Forgets everything `store` holds."
  @spec clear(t()) :: :ok
  def clear(%__MODULE__{name: name}), do: GenServer.call(name, :clear)

  defimpl WardrikStore.Adapter do
    def child_spec(%{name: name}),
      do: %{id: name, start: {WardrikStore.Memory, :start_link, [name]}}

    def check(_store), do: {:ok, "in this node's memory"}
    def quorum(_store, _size), do: 1

    # Its reads are current because there is only the one node.
    def durable_backend(store), do: {WardrikStore.Durable, store: store}

    def put(%{name: name}, ns, key, value, opts),
      do: GenServer.call(name, {:put, {ns, key}, value, Keyword.fetch(opts, :if_vsn)})

    def get(store, ns, key, _opts) do
      case lookup(store, ns, key) do
        {value, _vsn} -> value
        nil -> nil
      end
    end

    def lookup(%{name: name}, ns, key) do
      case :ets.lookup(name, {ns, key}) do
        [{_key, value, vsn}] -> {value, vsn}
        [] -> nil
      end
    end

    def delete(%{name: name}, ns, key, opts),
      do: GenServer.call(name, {:delete, {ns, key}, Keyword.fetch(opts, :if_vsn)})

    # The table is walked from the prefix to the first key past it, so no
    # other key is read.
    def keys(%{name: table}, ns, prefix) do
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
  end

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
