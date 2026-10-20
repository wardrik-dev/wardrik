defmodule Wardrik.Bus.EventTest do
  use ExUnit.Case, async: true

  alias Wardrik.Bus

  alias Wardrik.Bus.Event
  alias Wardrik.Bus.Source

  setup do
    {:ok, source: Source.root(Wardrik.Test.Fleet.id(), name: "turn")}
  end

  test "new/2 wraps a payload without publishing it", %{source: source} do
    :ok = Bus.subscribe(source.agent_id)

    event = Event.new(source, %Bus.Result{text: "a"})

    assert event.payload == %Bus.Result{text: "a"}
    assert event.source == source
    refute_receive %Event{}
  end

  test "type/1 names the event from its payload", %{source: source} do
    assert Event.new(source, %Bus.Thinking{text: "a"}) |> Event.type() == :thinking

    assert Event.new(source, %Bus.ToolFinished{
             call_id: "1",
             name: "echo",
             result: :ok,
             served_by: nil,
             cost: nil
           })
           |> Event.type() ==
             :tool_finished
  end

  test "root?/1 separates a turn's own events from work it spawned", %{source: source} do
    nested = Source.child(source, name: "echo")

    assert source |> Event.new(%Bus.Result{text: "a"}) |> Event.root?()
    refute nested |> Event.new(%Bus.Result{text: "a"}) |> Event.root?()
  end

  test "emit/2 publishes to the source's agent", %{source: source} do
    :ok = Bus.subscribe(source.agent_id)

    assert Event.emit(source, %Bus.Result{text: "a"}) == :ok
    assert_receive %Event{payload: %Bus.Result{text: "a"}}
  end

  test "nested work publishes to the same agent as its parent", %{source: source} do
    :ok = Bus.subscribe(source.agent_id)

    source |> Source.child(name: "echo") |> Event.emit(%Bus.Result{text: "nested"})

    assert_receive %Event{payload: %Bus.Result{text: "nested"}} = event
    refute Event.root?(event)
    assert event.source.trace.trace_id == source.trace.trace_id
  end

  describe "ended/1" do
    test "reads how a tool call ended from the event that settles it" do
      for {payload, ended} <- [
            {%Bus.ToolFinished{
               call_id: "c",
               name: "x",
               result: {:ok, %{"n" => 1}},
               served_by: nil,
               cost: nil
             }, :ok},
            {%Bus.ToolReplayed{call_id: "c", name: "x", result: {:error, :gone}},
             {:error, :gone}},
            {%Bus.ToolReplayed{
               call_id: "c",
               name: "x",
               result: Wardrik.Tool.Result.error(:nope)
             }, {:error, %{"code" => "nope", "message" => "nope"}}},
            {%Bus.ToolDenied{
               call_id: "c",
               name: "x",
               reason: "Never.",
               decided_by: %{by: :default, hooks: []}
             }, {:error, "Never."}},
            {%Bus.ToolParked{call_id: "c", name: "x", prompt: "Ship?"}, {:error, :parked}},
            {%Bus.SpanFinished{outcome: :ok, duration_ms: 1}, nil}
          ] do
        assert Event.ended(payload) == ended
      end
    end
  end

  describe "levels" do
    test "a tool call as it streams is raw" do
      assert Event.level(:tool_call) == :raw
    end

    test "the shape of the work is lifecycle" do
      for type <- [
            :turn_started,
            :turn_finished,
            :turn_parked,
            :span_started,
            :span_finished,
            :tool_started,
            :tool_finished,
            :tool_replayed,
            :tool_denied,
            :tool_parked,
            :delegation_started,
            :delegation_finished
          ] do
        assert Event.level(type) == :lifecycle
      end
    end

    test "everything else is activity" do
      for type <- [:model_started, :tool_progress, :result, :thinking, :meta] do
        assert Event.level(type) == :activity
      end
    end

    test "a type nobody has classified is activity" do
      assert Event.level(:something_added_later) == :activity
    end

    test "a level takes its own events and everything below it" do
      assert Event.delivers?(:lifecycle, :turn_started)
      refute Event.delivers?(:lifecycle, :result)

      assert Event.delivers?(:activity, :turn_started)
      assert Event.delivers?(:activity, :result)
      refute Event.delivers?(:activity, :tool_call)

      assert Event.delivers?(:raw, :result)
      assert Event.delivers?(:raw, :tool_call)
    end

    test "levels run from least to most" do
      assert Event.levels() == [:lifecycle, :activity, :raw]
    end
  end
end
