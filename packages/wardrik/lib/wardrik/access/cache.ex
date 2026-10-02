defmodule Wardrik.Access.Cache do
  @moduledoc """
  What this node last read of each record through consensus, and the records
  revoked here, each kept for one sweep. See `Wardrik.Access`.

  An entry is `{ref, value, until}`, or `{ref, :revoked, until}` for a
  revoked record, with `until` in monotonic milliseconds. A lookup after
  `until` is a miss. `put/2` never replaces a revocation still in force;
  `revoked/1` replaces whatever is there.

  The table belongs to `Wardrik.Access.Leases`, which purges what has lapsed
  every sweep, and goes with it: a node whose table is new reads every record
  through consensus again.
  """

  alias Wardrik.Access

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

  @doc "The value this node holds for `ref`, `:revoked`, or `:miss` where it holds nothing still good."
  @spec lookup(Access.ref()) :: {:ok, term()} | :revoked | :miss
  def lookup(ref) do
    now = now()

    case :ets.lookup(@table, ref) do
      [{^ref, :revoked, until}] when until > now -> :revoked
      [{^ref, value, until}] when until > now -> {:ok, value}
      _missing_or_lapsed -> :miss
    end
  end

  @doc "Keeps `value` for `ref` for a sweep, unless `ref` was revoked here within one."
  @spec put(Access.ref(), term()) :: :ok
  def put(ref, value) do
    entry = {ref, value, now() + Access.config(:sweep)}

    if not :ets.insert_new(@table, entry) do
      now = now()
      replaceable = [{:orelse, {:"=/=", :"$1", :revoked}, {:<, :"$2", now}}]

      _replaced =
        :ets.select_replace(@table, [{{ref, :"$1", :"$2"}, replaceable, [{:const, entry}]}])
    end

    :ok
  end

  @doc "Refuses `ref` on this node for a sweep, whatever it held."
  @spec revoked(Access.ref()) :: :ok
  def revoked(ref) do
    true = :ets.insert(@table, {ref, :revoked, now() + Access.config(:sweep)})
    :ok
  end

  @doc "Drops every entry that has lapsed."
  @spec purge() :: :ok
  def purge do
    now = now()
    _dropped = :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
