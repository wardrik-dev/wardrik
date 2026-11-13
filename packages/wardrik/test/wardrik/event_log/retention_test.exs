defmodule Wardrik.EventLog.RetentionTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog
  import Wardrik.EventLog.Test.Events

  alias Wardrik.EventLog.Cursor
  alias Wardrik.EventLog.Retention

  setup :start_events

  setup %{events: events} do
    stopped(events, "agt_1", ~U[2000-01-01 00:00:00Z])
    stopped(events, "agt_1", ~U[2000-01-02 00:00:00Z])
    stopped(events, "agt_1")
    :ok
  end

  defp dropped(events, cursor) do
    {:ok, %{events: [%{"type" => "wardrik.events.dropped"} = dropped | _rest]}} =
      Wardrik.EventLog.page(events, ["agt_1"], after: Cursor.encode(cursor))

    dropped["data"]
  end

  test "drops the events written before the cutoff, and says so to a reader after them", %{
    events: events
  } do
    :ok = Wardrik.EventLog.trim(events, ~U[2000-01-03 00:00:00Z])

    assert sequences(events, ["agt_1"]) == ["wardrik.events.dropped", "000000000003"]
    assert dropped(events, %{}) == %{"after" => 0, "oldest" => 3}
    assert dropped(events, %{{"agt_1", nil} => 1}) == %{"after" => 1, "oldest" => 3}

    assert sequences(events, ["agt_1"], after: Cursor.encode(%{{"agt_1", nil} => 2})) ==
             ["000000000003"]
  end

  test "reads back newest first only as far as the oldest event kept", %{events: events} do
    :ok = Wardrik.EventLog.trim(events, ~U[2000-01-03 00:00:00Z])

    assert {:ok, %{events: [%{"sequence" => "000000000003"}], next: next}} =
             Wardrik.EventLog.page(events, ["agt_1"], order: :newest, limit: 5)

    assert {:ok, %{{"agt_1", nil} => 2}} = Cursor.decode(next)

    assert {:ok, %{events: []}} =
             Wardrik.EventLog.page(events, ["agt_1"], order: :newest, before: next)
  end

  test "drops what's already dropped once", %{events: events} do
    :ok = Wardrik.EventLog.trim(events, ~U[2000-01-02 00:00:00Z])
    :ok = Wardrik.EventLog.trim(events, ~U[2000-01-02 00:00:00Z])
    :ok = Wardrik.EventLog.trim(events, ~U[2000-01-03 00:00:00Z])

    assert dropped(events, %{}) == %{"after" => 0, "oldest" => 3}
  end

  test "carries on numbering after every event is dropped and the events restart", %{
    events: events,
    store: store
  } do
    :ok = Wardrik.EventLog.trim(events, DateTime.add(DateTime.utc_now(), 1, :day))
    cursor = Wardrik.EventLog.head(events, ["agt_1"])
    assert {:ok, %{{"agt_1", nil} => 3}} = Cursor.decode(cursor)

    stop_supervised!(Wardrik.EventLog)
    start_supervised!({Wardrik.EventLog, name: events, store: store, deployment: "test"})
    trimmed(events)
    stopped(events, "agt_1")

    assert sequences(events, ["agt_1"]) == ["wardrik.events.dropped", "000000000004"]
  end

  test "trims as it starts and every hour after, keeping the days it's given", %{
    events: events
  } do
    {Retention, retention, :worker, _modules} =
      events
      |> Supervisor.which_children()
      |> List.keyfind(Retention, 0)

    send(retention, :trim)
    trimmed(events)

    assert sequences(events, ["agt_1"]) == ["wardrik.events.dropped", "000000000003"]
  end

  test "logs a trim it couldn't make", %{events: events} do
    expect(Wardrik.Store, :put, fn _store, _key, _value, _opts -> {:error, :down} end)

    assert capture_log(fn -> Wardrik.EventLog.trim(events, ~U[2000-01-03 00:00:00Z]) end) =~
             ~s(Couldn't trim {"agt_1", nil}'s events: :down)
  end

  test "keeps every event with infinite retention", %{store: store} do
    start_supervised!({Wardrik.EventLog, name: :infinite, store: store, retention: :infinity},
      id: :infinite
    )

    children = Supervisor.which_children(:infinite)
    refute List.keyfind(children, Retention, 0)
  end
end
