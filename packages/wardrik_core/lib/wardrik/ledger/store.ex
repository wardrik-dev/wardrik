defmodule Wardrik.Ledger.Store do
  @moduledoc """
  A `Wardrik.Ledger` over the host's `WardrikStore`, which each function is
  handed as `:store`, so nothing of the store is kept with the agents that
  name it.

  Entries are written under the `:claims` namespace, one per agent and call
  id, as the agent's ID, then `//`, which no ID holds, then the call id. A claim is a write conditional on nothing being written yet, so a second
  claim answers with the first one's state whatever adapter is underneath.

  ## Retention

  An entry lasts as long as the turn that made it, however long that turn
  waits on a person, and `forget/2` removes the turn's entries once it has
  ended.
  """

  defstruct []

  @type t() :: %__MODULE__{}

  alias Wardrik.Ledger.Entry

  @ns :claims

  @doc "The key an entry is written under, within the `:claims` namespace."
  @spec key(Wardrik.Ledger.key()) :: String.t()
  def key({agent_id, call_id}), do: "#{agent_id}//#{call_id}"

  @doc false
  def claim(key, call, store) do
    case WardrikStore.put(store, @ns, key(key), Entry.claimed(call), if_vsn: nil) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> held(store, key)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def settle(key, result, store) do
    encoded = key(key)

    case WardrikStore.lookup(store, @ns, encoded) do
      nil ->
        {:error, :not_claimed}

      {%Entry{} = entry, vsn} ->
        write(store, encoded, Entry.settled(entry, result), vsn)

      {other, _vsn} ->
        {:error, {:unexpected_entry, other}}
    end
  end

  # A claim that was settled since it was read is not the claim being
  # released, and stays.
  @doc false
  def release(key, store) do
    encoded = key(key)

    case WardrikStore.lookup(store, @ns, encoded) do
      {%Entry{result: nil}, vsn} -> delete(store, encoded, vsn)
      _settled_or_gone -> :ok
    end
  end

  defp delete(store, encoded, vsn) do
    case WardrikStore.delete(store, @ns, encoded, if_vsn: vsn) do
      :ok -> :ok
      {:error, :conflict} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Every key a turn claims starts with its agent and its trace id, the calls of
  # its delegations included, which share the trace.
  @doc false
  def forget(agent_id, trace_id, store) do
    store
    |> WardrikStore.keys(@ns, "#{agent_id}//#{trace_id}/")
    |> Enum.reduce_while(:ok, fn encoded, :ok ->
      case WardrikStore.lookup(store, @ns, encoded) do
        {_entry, vsn} -> delete(store, encoded, vsn) |> continue()
        nil -> {:cont, :ok}
      end
    end)
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, reason}), do: {:halt, {:error, reason}}

  @doc false
  def fetch(key, store) do
    case WardrikStore.get(store, @ns, key(key)) do
      %Entry{} = entry -> {:ok, entry}
      _other -> :error
    end
  end

  defp write(store, encoded, entry, vsn) do
    case WardrikStore.put(store, @ns, encoded, entry, if_vsn: vsn) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp held(store, key) do
    case WardrikStore.get(store, @ns, key(key), consistent: true) do
      %Entry{result: nil} = entry -> {:pending, entry}
      %Entry{result: result} -> {:settled, result}
      nil -> {:error, :forgotten}
      other -> {:error, {:unexpected_entry, other}}
    end
  end
end

defimpl Wardrik.Ledger, for: Wardrik.Ledger.Store do
  alias Wardrik.Ledger.Store

  def claim(_ledger, key, opts),
    do: Store.claim(key, Keyword.fetch!(opts, :call), Keyword.fetch!(opts, :store))

  def settle(_ledger, key, opts),
    do: Store.settle(key, Keyword.fetch!(opts, :result), Keyword.fetch!(opts, :store))

  def fetch(_ledger, key, opts), do: Store.fetch(key, Keyword.fetch!(opts, :store))
  def release(_ledger, key, opts), do: Store.release(key, Keyword.fetch!(opts, :store))

  def forget(_ledger, agent_id, opts),
    do: Store.forget(agent_id, Keyword.fetch!(opts, :trace), Keyword.fetch!(opts, :store))
end
