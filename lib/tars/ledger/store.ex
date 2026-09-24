defmodule Tars.Ledger.Store do
  @moduledoc """
  A `Tars.Ledger` over `Tars.Store`.

  Entries are written under the `:claims` namespace, one per agent and call
  id. A claim is a write conditional on nothing being written yet, so a second
  claim answers with the first one's state whatever adapter is underneath.

  ## Retention

  Entries expire, since a claim is only worth holding while the turn that made
  it can still be replayed. The default is seven days.

      config :tars, Tars.Ledger.Store, ttl_ms: :timer.hours(24)
  """

  @behaviour Tars.Ledger

  alias Tars.Ledger.Entry
  alias Tars.Store

  @ns :claims
  @default_ttl_ms 7 * 24 * 60 * 60 * 1000

  @doc "The key an entry is written under, within the `:claims` namespace."
  @spec key(Tars.Ledger.key()) :: String.t()
  def key({agent_id, call_id}), do: agent_id <> "/" <> call_id

  @impl Tars.Ledger
  def claim(key, call) do
    case Store.put(@ns, key(key), Entry.claimed(call), if_vsn: nil, ttl_ms: ttl_ms()) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> held(key)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Tars.Ledger
  def settle(key, result) do
    encoded = key(key)

    case Store.lookup(@ns, encoded) do
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
  @impl Tars.Ledger
  def release(key) do
    encoded = key(key)

    case Store.lookup(@ns, encoded) do
      {%Entry{result: nil}, vsn} -> delete(encoded, vsn)
      _settled_or_gone -> :ok
    end
  end

  defp delete(encoded, vsn) do
    case Store.delete(@ns, encoded, if_vsn: vsn) do
      :ok -> :ok
      {:error, :conflict} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Tars.Ledger
  def fetch(key) do
    case Store.get(@ns, key(key)) do
      %Entry{} = entry -> {:ok, entry}
      _other -> :error
    end
  end

  defp write(encoded, entry, vsn) do
    case Store.put(@ns, encoded, entry, if_vsn: vsn, ttl_ms: ttl_ms()) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp held(key) do
    case Store.get(@ns, key(key), consistent: true) do
      %Entry{result: nil} = entry -> {:pending, entry}
      %Entry{result: result} -> {:settled, result}
      nil -> {:error, :expired}
      other -> {:error, {:unexpected_entry, other}}
    end
  end

  defp ttl_ms do
    :tars
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end
end
