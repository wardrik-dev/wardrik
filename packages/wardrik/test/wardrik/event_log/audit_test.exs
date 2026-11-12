defmodule Wardrik.EventLog.AuditTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.EventLog.Test.Events
  import Wardrik.EventLog.Test.Protocol

  alias WardrikCore.Principal

  setup :start_events

  defp forgotten(agent),
    do: {"agent.forgotten", "agents/" <> agent, %{"agent" => %{"id" => agent}}}

  test "records who changed what, and who acted for them", %{events: events} do
    actor = %Principal{id: "acme/@jon", attributes: %{name: "Jon"}}
    assistant = %Principal{id: "acme/agent/helper"}

    assert :ok =
             Wardrik.EventLog.record(events, forgotten("agt_1"),
               actor: actor,
               assumed_by: [assistant]
             )

    assert :ok = Wardrik.EventLog.record(events, forgotten("agt_2"))

    assert %{events: [first, second], next: 2} = Wardrik.EventLog.audit(events)

    assert %{
             "source" => "wardrik://test/audit",
             "subject" => "agents/agt_1",
             "sequence" => "000000000001",
             "data" => %{
               "agent" => %{"id" => "agt_1"},
               "actor" => %{"id" => "acme/@jon", "name" => "Jon"},
               "assumed_by" => [%{"id" => "acme/agent/helper"}]
             }
           } = valid!(first)

    refute Map.has_key?(valid!(second)["data"], "actor")
  end

  test "pages through the changes", %{events: events} do
    for agent <- ["agt_1", "agt_2", "agt_3"],
        do: :ok = Wardrik.EventLog.record(events, forgotten(agent))

    assert %{events: [_, _], next: 2} = Wardrik.EventLog.audit(events, limit: 2)

    assert %{events: [%{"sequence" => "000000000003"}], next: 3} =
             Wardrik.EventLog.audit(events, after: 2)

    assert %{events: [], next: 3} = Wardrik.EventLog.audit(events, after: 3)
  end

  test "keeps its numbers apart from an agent named audit", %{events: events} do
    stopped(events, "audit")
    :ok = Wardrik.EventLog.record(events, forgotten("audit"))

    assert sequences(events, ["audit"]) == ["000000000001"]
    assert %{events: [%{"sequence" => "000000000001"}]} = Wardrik.EventLog.audit(events)
  end

  test "says so when the changes asked for were trimmed", %{events: events} do
    :ok = Wardrik.EventLog.record(events, forgotten("agt_1"))
    :ok = Wardrik.EventLog.trim(events, DateTime.add(DateTime.utc_now(), 1, :day))

    assert %{events: [dropped], next: 1} = Wardrik.EventLog.audit(events)

    assert %{"type" => "wardrik.events.dropped", "source" => "wardrik://test/audit"} =
             valid!(dropped)
  end

  test "returns the store's refusal", %{events: events} do
    expect(Wardrik.Store, :put, fn _store, _key, _value, _opts -> {:error, :down} end)

    assert {:error, :down} = Wardrik.EventLog.record(events, forgotten("agt_1"))
  end
end
