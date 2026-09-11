defmodule Tars.EventTest do
  use ExUnit.Case, async: true

  alias Tars.Event
  alias Tars.Event.Source

  setup do
    {:ok, source: Source.root(make_ref(), name: "turn")}
  end

  test "new/2 wraps a payload without publishing it", %{source: source} do
    :ok = Event.Bus.subscribe(source.agent_id)

    event = Event.new(source, {:result, "a"})

    assert event.payload == {:result, "a"}
    assert event.source == source
    refute_receive %Event{}
  end

  test "type/1 names the event from its payload", %{source: source} do
    assert Event.new(source, {:chunk, "a"}) |> Event.type() == :chunk
    assert Event.new(source, {:tool_finished, "1", "echo", :ok}) |> Event.type() == :tool_finished
  end

  test "root?/1 separates a turn's own events from work it spawned", %{source: source} do
    nested = Source.child(source, name: "echo")

    assert source |> Event.new({:result, "a"}) |> Event.root?()
    refute nested |> Event.new({:result, "a"}) |> Event.root?()
  end

  test "emit/2 publishes to the source's agent", %{source: source} do
    :ok = Event.Bus.subscribe(source.agent_id)

    assert Event.emit(source, {:result, "a"}) == :ok
    assert_receive %Event{payload: {:result, "a"}}
  end

  test "nested work publishes to the same agent as its parent", %{source: source} do
    :ok = Event.Bus.subscribe(source.agent_id)

    source |> Source.child(name: "echo") |> Event.emit({:result, "nested"})

    assert_receive %Event{payload: {:result, "nested"}} = event
    refute Event.root?(event)
    assert event.source.trace.trace_id == source.trace.trace_id
  end

  describe "levels" do
    test "the provider's own stream records are raw" do
      assert Event.level(:chunk) == :raw
      assert Event.level(:tool_call) == :raw
    end

    test "everything else is activity" do
      for type <- [:turn_started, :span_started, :model_started, :tool_started, :result, :meta] do
        assert Event.level(type) == :activity
      end
    end

    test "a type nobody has classified is activity" do
      assert Event.level(:something_added_later) == :activity
    end

    test "a level takes its own events and everything below it" do
      assert Event.delivers?(:activity, :result)
      refute Event.delivers?(:activity, :chunk)

      assert Event.delivers?(:raw, :result)
      assert Event.delivers?(:raw, :chunk)
    end

    test "levels run from least to most" do
      assert Event.levels() == [:activity, :raw]
    end
  end
end
