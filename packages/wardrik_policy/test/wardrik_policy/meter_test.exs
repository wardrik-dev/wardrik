defmodule WardrikPolicy.MeterTest do
  use ExUnit.Case, async: false

  alias WardrikPolicy.Meter
  alias WardrikPolicy.Spend

  setup do
    %{
      key:
        Spend.key(
          Wardrik.AgentID.parse!("meter-#{System.unique_integer([:positive])}/a"),
          "day:2026-09-23"
        )
    }
  end

  test "a period nothing has spent in reads as nothing", %{key: key} do
    assert {:ok, %Spend{micro_usd: 0, tokens: 0, granted_micro_usd: 0, granted_tokens: 0}} =
             Meter.read(key)
  end

  test "spends and grants add up", %{key: key} do
    :ok = Meter.spend(key, 250_000, 100)
    :ok = Meter.spend(key, 500_000, 50)
    :ok = Meter.grant(key, 1_000_000, 1000)

    assert {:ok,
            %Spend{
              micro_usd: 750_000,
              tokens: 150,
              granted_micro_usd: 1_000_000,
              granted_tokens: 1000
            }} = Meter.read(key)
  end

  test "a node running no meters answers that none is available" do
    :ok = Supervisor.terminate_child(Wardrik.Test.Supervisor, WardrikPolicy.Supervisor)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(Wardrik.Test.Supervisor, WardrikPolicy.Supervisor)
    end)

    assert {:error, {:meter_unavailable, _reason}} = Meter.read("nobody|total")
  end

  test "one process holds a period, and its spend outlives it", %{key: key} do
    :ok = Meter.spend(key, 250_000, 100)
    {pid, _meta} = DurableServer.Supervisor.lookup(Meter.supervisor(), key)

    :ok = DurableServer.Supervisor.terminate_child(Meter.supervisor(), key)
    refute Process.alive?(pid)

    assert {:ok, %Spend{micro_usd: 250_000, tokens: 100}} = Meter.read(key)
  end
end
