defmodule Wardrik.Event.ExportTest do
  # The audit log is the node's, and another test empties it.
  use ExUnit.Case, async: false
  use Mimic

  alias Wardrik.Audit
  alias Wardrik.Event
  alias Wardrik.Event.Export
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Event.Source

  setup :verify_on_exit!

  setup do
    first = Wardrik.Test.Fleet.id("export")
    second = Wardrik.Test.Fleet.id("export")
    name = "export-#{System.unique_integer([:positive])}"

    %{first: first, second: second, name: name, logs: &(&1 in [first, second])}
  end

  # A log for `agent_id`, opened as its agent opens it, with `count` runs
  # started after `agent.started`, the first `old` of them, and the start
  # before them, long ago.
  defp written(agent_id, count, old \\ 0) do
    started =
      Event.new(Source.root(agent_id), %Event.AgentStarted{
        node: node(),
        status: :idle,
        generation: "g1"
      })

    started = if old > 0, do: %{started | at: days_ago(31)}, else: started
    writer = Writer.open(Writer.new(agent_id), started)

    Enum.reduce(1..count//1, writer, fn n, writer ->
      event = Event.new(Source.root(agent_id), %Event.TurnStarted{messages: []})
      event = if n <= old, do: %{event | at: days_ago(31)}, else: event
      {:ok, writer} = Writer.append(writer, event)
      writer
    end)
  end

  defp days_ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.to_unix(:microsecond)

  defp from(events), do: Enum.map(events, &{&1["source"], &1["sequence"]})

  defp source(id), do: Wardrik.Event.Codec.source(id)

  test "reads every log from the start, and again until the cursor moves", ctx do
    %{first: first, second: second, name: name, logs: logs} = ctx
    written(first, 1)
    written(second, 0)

    assert {:ok, %Export{events: events, next: next, gaps: []}} = Export.read(name, logs: logs)

    assert from(events) == [
             {source(first), "000000000001"},
             {source(first), "000000000002"},
             {source(second), "000000000001"}
           ]

    assert {:ok, %Export{events: ^events}} = Export.read(name, logs: logs)

    assert :ok = Export.advance(name, next)
    assert Export.cursor(name) == %{to_string(first) => 2, to_string(second) => 1}
    assert {:ok, %Export{events: []}} = Export.read(name, logs: logs)

    written(second, 1)
    assert {:ok, %Export{events: events}} = Export.read(name, logs: logs)
    assert from(events) == [{source(second), "000000000002"}, {source(second), "000000000003"}]
  end

  test "takes as many as asked, log by log, and names only the logs it read", ctx do
    %{first: first, second: second, name: name, logs: logs} = ctx
    written(first, 2)
    written(second, 2)

    {:ok, page} = Export.read(name, logs: logs, limit: 2)
    assert from(page.events) == [{source(first), "000000000001"}, {source(first), "000000000002"}]
    :ok = Export.advance(name, page.next)
    assert Export.cursor(name) == %{to_string(first) => 2}

    {:ok, later} = Export.read(name, logs: logs, limit: 2)

    assert from(later.events) == [
             {source(first), "000000000003"},
             {source(second), "000000000001"}
           ]

    :ok = Export.advance(name, later.next)
    :ok = Export.advance(name, page.next)
    assert Export.cursor(name) == %{to_string(first) => 3, to_string(second) => 1}
  end

  test "reads a log trimmed past the cursor from its oldest, and says so", ctx do
    %{first: first, name: name} = ctx
    written(first, 3, 2)
    :ok = Log.trim(first, 4, DateTime.add(DateTime.utc_now(), -30, :day))

    assert {:ok, page} = Export.read(name, logs: &(&1 == first))
    assert from(page.events) == [{source(first), "000000000004"}]
    assert page.gaps == [%{log: first, after: 0, oldest: 4}]

    :ok = Export.advance(name, page.next)
    assert {:ok, %Export{events: [], gaps: []}} = Export.read(name, logs: &(&1 == first))
  end

  test "reads the audit, and a forgotten agent's log", %{name: name} do
    {id, _pid} = Wardrik.Test.Fleet.start_agent()
    :ok = Wardrik.Fleet.forget(id)
    :ok = Audit.record({:agent_forgotten, id}, nil)

    assert id in Log.logs()
    assert hd(Log.logs()) == :audit

    {:ok, page} = Export.read(name, logs: &(&1 in [id, :audit]), limit: 1_000)

    assert {source(:audit), "wardrik.agent.forgotten"} in Enum.map(
             page.events,
             &{&1["source"], &1["type"]}
           )

    assert List.last(page.events)["source"] == source(id)
  end

  test "moves a cursor another reader moved first", %{first: first, name: name} do
    written(first, 0)
    {:ok, page} = Export.read(name, logs: &(&1 == first))

    expect(WardrikStore, :put, fn ns, key, _cursor, _opts ->
      {:ok, _vsn} = call_original(WardrikStore, :put, [ns, key, %{"audit" => 9}, [if_vsn: nil]])
      {:error, :conflict}
    end)

    assert :ok = Export.advance(name, page.next)
    assert Export.cursor(name) == %{"audit" => 9, to_string(first) => 1}
  end

  test "refuses a next it did not answer, and forgets a cursor", %{first: first, name: name} do
    assert Export.advance(name, "not a page") == {:error, :invalid}

    assert Export.advance(name, Base.url_encode64(~s({"nobody": 1}), padding: false)) ==
             {:error, :invalid}

    assert Export.advance(name, Base.url_encode64(~s({"audit": -1}), padding: false)) ==
             {:error, :invalid}

    written(first, 0)
    {:ok, page} = Export.read(name, logs: &(&1 == first))
    :ok = Export.advance(name, page.next)

    assert :ok = Export.forget(name)
    assert Export.cursor(name) == %{}
    assert :ok = Export.forget(name)
    assert {:ok, %Export{events: [_started]}} = Export.read(name, logs: &(&1 == first))
  end
end
