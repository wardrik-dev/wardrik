defmodule Tars.Ledger.EKV do
  @moduledoc """
  A `Tars.Ledger` over the store the fleet already runs on.

  Entries are written under `#{inspect("tars/claims/")}`, beside the agent
  state `Tars.Fleet` keeps under its own prefix. The two never share a key:
  EKV settles a key into compare-and-swap mode on its first such write and
  refuses eventual writes to it afterwards, so a key written both ways would
  be a fault rather than a race.

  A claim is one `if_vsn: nil` write, which succeeds only where nothing is
  written yet. That is the whole mechanism. Against a single node it is a
  local transaction; against several it needs quorum, and a claim that cannot
  reach quorum fails rather than proceeding unrecorded.

  ## Retention

  Entries expire, since a claim is only worth holding while the turn that made
  it can still be replayed. The default is seven days.

      config :tars, Tars.Ledger.EKV, ttl_ms: :timer.hours(24)
  """

  @behaviour Tars.Ledger

  alias Tars.Fleet
  alias Tars.Ledger.Entry

  @prefix "tars/claims/"
  @default_ttl_ms 7 * 24 * 60 * 60 * 1000

  @doc "The key an entry is written under."
  @spec key(Tars.Ledger.key()) :: String.t()
  def key({agent_id, call_id}), do: @prefix <> agent_id <> "/" <> call_id

  @doc "The prefix every entry is written under."
  @spec prefix() :: String.t()
  def prefix, do: @prefix

  @impl Tars.Ledger
  def claim(key, call) do
    entry = Entry.claimed(call)

    case EKV.put(Fleet.Supervisor.store(), key(key), entry, put_opts(if_vsn: nil)) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> held(key)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Tars.Ledger
  def settle(key, result) do
    encoded = key(key)

    case EKV.lookup(Fleet.Supervisor.store(), encoded) do
      nil ->
        {:error, :not_claimed}

      {%Entry{} = entry, vsn} ->
        write(encoded, Entry.settled(entry, result), vsn)

      {other, _vsn} ->
        {:error, {:unexpected_entry, other}}
    end
  end

  @impl Tars.Ledger
  def fetch(key) do
    case EKV.get(Fleet.Supervisor.store(), key(key)) do
      %Entry{} = entry -> {:ok, entry}
      _other -> :error
    end
  end

  defp write(encoded, entry, vsn) do
    case EKV.put(Fleet.Supervisor.store(), encoded, entry, put_opts(if_vsn: vsn)) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A conflicting claim is read back through consensus: the eventual read is
  # allowed to be behind the write that just lost, and being behind here means
  # reporting work as unrun.
  defp held(key) do
    case EKV.get(Fleet.Supervisor.store(), key(key), consistent: true) do
      %Entry{result: nil} = entry -> {:pending, entry}
      %Entry{result: result} -> {:settled, result}
      nil -> {:error, :expired}
      other -> {:error, {:unexpected_entry, other}}
    end
  end

  # Ambiguity is resolved in the store rather than returned: EKV's own barrier
  # read settles an unconfirmed write, leaving conflict and unavailability as
  # the only ways a claim does not land.
  defp put_opts(opts), do: Keyword.merge([ttl: ttl_ms(), resolve_unconfirmed: true], opts)

  defp ttl_ms do
    :tars
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end
end
