defmodule Wardrik.Ledger.Store do
  @moduledoc """
  A `Wardrik.Ledger` over `WardrikStore`.

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
  def claim(key, call) do
    case WardrikStore.put(@ns, key(key), Entry.claimed(call), if_vsn: nil) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> held(key)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Wardrik.Ledger
  def settle(key, result) do
    encoded = key(key)

    case WardrikStore.lookup(@ns, encoded) do
      nil ->
        {:error, :not_claimed}

      {%Entry{} = entry, vsn} ->
        write(encoded, Entry.settled(entry, result), vsn)

      {other, _vsn} ->
        {:error, {:unexpected_entry, other}}
    end
  end

  # A claim that was settled since it was read is not the claim being
  # released, and stays.
  @impl Wardrik.Ledger
  def release(key) do
    encoded = key(key)

    case WardrikStore.lookup(@ns, encoded) do
      {%Entry{result: nil}, vsn} -> delete(encoded, vsn)
      _settled_or_gone -> :ok
    end
  end

  defp delete(encoded, vsn) do
    case WardrikStore.delete(@ns, encoded, if_vsn: vsn) do
      :ok -> :ok
      {:error, :conflict} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Every key a turn claims starts with its agent and its trace id, the calls of
  # its delegations included, which share the trace.
  @impl Wardrik.Ledger
  def forget(agent_id, trace_id) do
    @ns
    |> WardrikStore.keys("#{agent_id}//#{trace_id}/")
    |> Enum.reduce_while(:ok, fn encoded, :ok ->
      case WardrikStore.lookup(@ns, encoded) do
        {_entry, vsn} -> delete(encoded, vsn) |> continue()
        nil -> {:cont, :ok}
      end
    end)
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue({:error, reason}), do: {:halt, {:error, reason}}

  @impl Wardrik.Ledger
  def fetch(key) do
    case WardrikStore.get(@ns, key(key)) do
      %Entry{} = entry -> {:ok, entry}
      _other -> :error
    end
  end

  defp write(encoded, entry, vsn) do
    case WardrikStore.put(@ns, encoded, entry, if_vsn: vsn) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp held(key) do
    case WardrikStore.get(@ns, key(key), consistent: true) do
      %Entry{result: nil} = entry -> {:pending, entry}
      %Entry{result: result} -> {:settled, result}
      nil -> {:error, :forgotten}
      other -> {:error, {:unexpected_entry, other}}
    end
  end
end
