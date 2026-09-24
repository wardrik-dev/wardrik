defmodule TarsPolicy.LedgerTest do
  use ExUnit.Case, async: false

  alias TarsPolicy.Ledger
  alias TarsPolicy.Spend

  setup do
    %{key: Spend.key("ledger-#{System.unique_integer([:positive])}/_/a", "day:2026-09-23")}
  end

  test "a period nothing has spent in reads as nothing", %{key: key} do
    assert {:ok, %Spend{micro_usd: 0, tokens: 0, granted_micro_usd: 0, granted_tokens: 0}} =
             Ledger.read(key)
  end

  test "spends and grants add up", %{key: key} do
    :ok = Ledger.spend(key, 250_000, 100)
    :ok = Ledger.spend(key, 500_000, 50)
    :ok = Ledger.grant(key, 1_000_000, 1000)

    assert {:ok,
            %Spend{
              micro_usd: 750_000,
              tokens: 150,
              granted_micro_usd: 1_000_000,
              granted_tokens: 1000
            }} = Ledger.read(key)
  end

  test "a node running no ledgers answers that none is available" do
    :ok = Supervisor.terminate_child(Tars.Supervisor, TarsPolicy.Supervisor)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(Tars.Supervisor, TarsPolicy.Supervisor)
    end)

    assert {:error, {:ledger_unavailable, _reason}} = Ledger.read("nobody|total")
  end

  test "one process holds a period, and its spend outlives it", %{key: key} do
    :ok = Ledger.spend(key, 250_000, 100)
    {pid, _meta} = DurableServer.Supervisor.lookup(Ledger.supervisor(), key)

    :ok = DurableServer.Supervisor.terminate_child(Ledger.supervisor(), key)
    refute Process.alive?(pid)

    assert {:ok, %Spend{micro_usd: 250_000, tokens: 100}} = Ledger.read(key)
  end
end
