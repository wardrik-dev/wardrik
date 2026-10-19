defmodule Wardrik.AuditTest do
  # One audit log for the node, emptied before each test.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]
  use Mimic

  import ExUnit.CaptureLog

  alias Wardrik.Audit
  alias Wardrik.Event.Log
  alias Wardrik.Principal

  setup :verify_on_exit!

  setup do
    empty()

    %{
      by: Principal.new("shell:jon"),
      id: Wardrik.AgentID.parse!("acme/triage")
    }
  end

  defp empty do
    for key <- WardrikStore.keys(store(), Log.namespace(), "audit//") do
      {_value, vsn} = WardrikStore.lookup(store(), Log.namespace(), key)
      :ok = WardrikStore.delete(store(), Log.namespace(), key, if_vsn: vsn)
    end

    restart()
  end

  defp restart do
    :ok = Supervisor.terminate_child(Wardrik.Core, Audit)
    {:ok, _pid} = Supervisor.restart_child(Wardrik.Core, Audit)
  end

  defp allow_store, do: Mimic.allow(WardrikStore, self(), Process.whereis(Audit))

  defp sequences do
    {:ok, events} = Log.read(store(), :audit, starting_after: Log.oldest(store(), :audit) - 1)
    Enum.map(events, &String.to_integer(&1["sequence"]))
  end

  defp written(sequence, at) do
    event = %{"id" => "elsewhere", "time" => DateTime.to_iso8601(at)}

    {:ok, _vsn} =
      WardrikStore.put(store(), Log.namespace(), Log.key(:audit, sequence), event, if_vsn: nil)
  end

  test "numbers each change, and says who made it", %{by: by, id: id} do
    agent = Wardrik.Principal.new("acme/agent/front")
    assert :ok = Audit.record(Wardrik.Audit, {:agent_forgotten, id}, by: by, assumed_by: [agent])
    assert :ok = Audit.record(Wardrik.Audit, {:agent_cleared, id}, by: nil)

    assert {:ok,
            [
              %{
                "type" => "wardrik.agent.forgotten",
                "sequence" => "000000000001",
                "data" => %{
                  "actor" => %{"id" => "shell:jon"},
                  "assumed_by" => [%{"id" => "acme/agent/front"}]
                }
              },
              %{"type" => "wardrik.agent.cleared", "sequence" => "000000000002", "data" => data}
            ]} = Log.read(store(), :audit)

    refute Map.has_key?(data, "actor")
    refute Map.has_key?(data, "assumed_by")
  end

  test "carries on from the end, after starting again", %{by: by, id: id} do
    :ok = Audit.record(Wardrik.Audit, {:agent_stopped, id}, by: by)
    restart()
    :ok = Audit.record(Wardrik.Audit, {:agent_spawned, id, node()}, by: by)

    assert sequences() == [1, 2]
  end

  test "writes past what another node wrote first", %{by: by, id: id} do
    :ok = Audit.record(Wardrik.Audit, {:agent_stopped, id}, by: by)
    written(2, DateTime.utc_now())
    written(3, DateTime.utc_now())

    :ok = Audit.record(Wardrik.Audit, {:agent_spawned, id, node()}, by: by)

    assert {:ok, [_, %{"id" => "elsewhere"}, %{"id" => "elsewhere"}, spawned]} =
             Log.read(store(), :audit)

    assert %{"type" => "wardrik.agent.spawned", "sequence" => "000000000004"} = spawned
  end

  test "leaves the number of a change the store failed to the next", %{by: by, id: id} do
    allow_store()
    expect(WardrikStore, :put, fn _store, _ns, _key, _event, _opts -> {:error, :unavailable} end)

    assert capture_log(fn ->
             assert :ok = Audit.record(Wardrik.Audit, {:agent_stopped, id}, by: by)
           end) =~
             "Could not write wardrik.agent.stopped to the audit log: :unavailable"

    :ok = Audit.record(Wardrik.Audit, {:agent_spawned, id, node()}, by: by)

    assert {:ok, [%{"type" => "wardrik.agent.spawned", "sequence" => "000000000001"}]} =
             Log.read(store(), :audit)
  end

  test "drops what is older than the log keeps", %{by: by, id: id} do
    written(1, DateTime.add(DateTime.utc_now(), -31, :day))
    written(2, DateTime.add(DateTime.utc_now(), -31, :day))

    :ok = Audit.record(Wardrik.Audit, {:agent_stopped, id}, by: by)
    # Trimmed after the reply; a second call waits for it.
    _state = :sys.get_state(Audit)

    assert {:gap, 3} = Log.read(store(), :audit)
    assert sequences() == [3]
  end

  test "leaves a trim to another node that got there first", %{by: by, id: id} do
    written(1, DateTime.add(DateTime.utc_now(), -31, :day))
    allow_store()

    stub(WardrikStore, :put, fn
      _store, _ns, "audit//dropped", _last, _opts ->
        {:error, :conflict}

      store, ns, key, value, opts ->
        call_original(WardrikStore, :put, [store, ns, key, value, opts])
    end)

    assert capture_log(fn ->
             :ok = Audit.record(Wardrik.Audit, {:agent_stopped, id}, by: by)
             _state = :sys.get_state(Audit)
           end) == ""
  end
end
