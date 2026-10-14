defmodule Wardrik.Ledger.Store do
  @moduledoc """
  A `Wardrik.Ledger` over the host's `WardrikStore`.

  Entries are written under the `:claims` namespace, one per agent and call
  id, as the agent's ID, then `//`, which no ID holds, then the call id. A claim is a write conditional on nothing being written yet, so a second
  claim answers with the first one's state whatever adapter is underneath.

  ## Retention

  An entry lasts as long as the turn that made it, however long that turn
  waits on a person, and `forget/2` removes the turn's entries once it has
  ended.
  """

  @behaviour Wardrik.Ledger

  alias Wardrik.Ledger.Entry

  @ns :claims

  @doc "The key an entry is written under, within the `:claims` namespace."
  @spec key(Wardrik.Ledger.key()) :: String.t()
  def key({agent_id, call_id}), do: "#{agent_id}//#{call_id}"

  @impl Wardrik.Ledger
  def claim(host, key, call) do
    store = Wardrik.Host.store(host)

    case WardrikStore.put(store, @ns, key(key), Entry.claimed(call), if_vsn: nil) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> held(store, key)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Wardrik.Ledger
  def settle(host, key, result) do
    store = Wardrik.Host.store(host)
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
  @impl Wardrik.Ledger
  def release(host, key) do
    store = Wardrik.Host.store(host)
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
  @impl Wardrik.Ledger
  def forget(host, agent_id, trace_id) do
    store = Wardrik.Host.store(host)

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

  @impl Wardrik.Ledger
  def fetch(host, key) do
    case WardrikStore.get(Wardrik.Host.store(host), @ns, key(key)) do
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
