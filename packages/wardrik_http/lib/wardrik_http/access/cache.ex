defmodule WardrikHTTP.Access.Cache do
  @moduledoc """
  What this node last read of each record through consensus, and the records
  revoked here, each kept until a purge finds it a sweep old: at least one
  sweep, and less than two. See `WardrikHTTP.Access`.

  An entry is `{ref, value, at}`, or `{ref, :revoked, at}` for a revoked
  record, with `at` the monotonic millisecond it was written. `put/2` never
  replaces a revocation still held; `revoked/1` replaces whatever is there.

  The table belongs to `WardrikHTTP.Access.Leases`, which purges what is a
  sweep old every sweep, as its own `:sweep` says, and goes with it: a node
  whose table is new reads every record through consensus again.
  """

  alias WardrikHTTP.Access

  @table __MODULE__

  @doc false
  @spec new() :: :ok
  def new do
    _table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    :ok
  end

  @doc "The value this node holds for `ref`, `:revoked`, or `:miss` where it holds nothing."
  @spec lookup(Access.ref()) :: {:ok, term()} | :revoked | :miss
  def lookup(ref) do
    case :ets.lookup(@table, ref) do
      [{^ref, :revoked, _at}] -> :revoked
      [{^ref, value, _at}] -> {:ok, value}
      [] -> :miss
    end
  end

  @doc "Keeps `value` for `ref`, unless `ref` was revoked here and is still held so."
  @spec put(Access.ref(), term()) :: :ok
  def put(ref, value) do
    entry = {ref, value, now()}

    if not :ets.insert_new(@table, entry) do
      replaceable = [{:"=/=", :"$1", :revoked}]

      _replaced =
        :ets.select_replace(@table, [{{ref, :"$1", :_}, replaceable, [{:const, entry}]}])
    end

    :ok
  end

  @doc "Refuses `ref` on this node until a purge finds it a sweep old, whatever it held."
  @spec revoked(Access.ref()) :: :ok
  def revoked(ref) do
    true = :ets.insert(@table, {ref, :revoked, now()})
    :ok
  end

  @doc "Drops every entry written `sweep` milliseconds ago or more."
  @spec purge(pos_integer()) :: :ok
  def purge(sweep) do
    cutoff = now() - sweep
    _dropped = :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", cutoff}], [true]}])
    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
