defmodule Tars.EventTest do
  use ExUnit.Case, async: true

  alias Tars.Event
  alias Tars.Event.Source

  setup do
    {:ok, source: Source.root(make_ref(), name: "turn")}
  end

  test "new/2 wraps a payload without publishing it", %{source: source} do
    :ok = Event.Bus.subscribe(source.agent_id)

    event = Event.new(source, {:chunk, "a"})

    assert event.payload == {:chunk, "a"}
    assert event.source == source
    refute_receive %Event{}
  end

  test "type/1 names the event from its payload", %{source: source} do
    assert Event.new(source, {:chunk, "a"}) |> Event.type() == :chunk
    assert Event.new(source, {:tool_finished, "1", "echo", :ok}) |> Event.type() == :tool_finished
  end

  test "root?/1 separates a turn's own events from work it spawned", %{source: source} do
    nested = Source.child(source, name: "echo")

    assert source |> Event.new({:chunk, "a"}) |> Event.root?()
    refute nested |> Event.new({:chunk, "a"}) |> Event.root?()
  end

  test "emit/2 publishes to the source's agent", %{source: source} do
    :ok = Event.Bus.subscribe(source.agent_id)

    assert Event.emit(source, {:chunk, "a"}) == :ok
    assert_receive %Event{payload: {:chunk, "a"}}
  end

  test "nested work publishes to the same agent as its parent", %{source: source} do
    :ok = Event.Bus.subscribe(source.agent_id)

    source |> Source.child(name: "echo") |> Event.emit({:chunk, "nested"})

    assert_receive %Event{payload: {:chunk, "nested"}} = event
    refute Event.root?(event)
    assert event.source.trace.trace_id == source.trace.trace_id
  end
end
