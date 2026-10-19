defmodule WardrikTUI.ActivityTest do
  use ExUnit.Case, async: true

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias Wardrik.Agent.Message
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Event
  alias Wardrik.Event.Source
  alias WardrikTUI.Activity

  defp event(source, payload), do: Event.new(source, payload)

  defp fold(activity, source, payload, now \\ 0) do
    Activity.fold(activity, event(source, payload), now: now)
  end

  setup do
    turn = Source.root(~A"test/assistant", name: "turn")
    {:ok, turn: turn, tool: Source.child(turn, name: "deep_research")}
  end

  describe "opening" do
    test "a turn opens the root span", %{turn: turn} do
      activity = Activity.new() |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})

      assert [span] = Activity.spans(activity)
      assert span.span_id == turn.trace.span_id
      assert span.name == "turn"
      assert span.status == :running
    end

    test "span_started opens a child", %{turn: turn, tool: tool} do
      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})
        |> fold(tool, %Event.SpanStarted{name: "deep_research"})

      assert [_turn, span] = Activity.spans(activity)
      assert span.name == "deep_research"
      assert span.parent_span_id == turn.trace.span_id
    end

    test "a span first seen mid-flight is opened where it was seen", %{tool: tool} do
      activity = Activity.new() |> fold(tool, %Event.Result{text: "already going"})

      assert [span] = Activity.spans(activity)
      assert span.span_id == tool.trace.span_id
      assert span.status == :running
      assert span.doing == "answering"
    end

    test "spans keep the order they were first seen", %{turn: turn} do
      one = Source.child(turn, name: "one")
      two = Source.child(turn, name: "two")

      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})
        |> fold(one, %Event.SpanStarted{name: "one"})
        |> fold(two, %Event.SpanStarted{name: "two"})
        |> fold(one, %Event.Result{text: "still going"})

      assert Enum.map(Activity.spans(activity), & &1.name) == ["turn", "one", "two"]
    end
  end

  describe "closing" do
    test "span_finished settles a span with the duration it reported", %{turn: turn, tool: tool} do
      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})
        |> fold(tool, %Event.SpanStarted{name: "deep_research"})
        |> fold(tool, %Event.SpanFinished{outcome: :ok, duration_ms: 1234})

      span = Activity.fetch(activity, tool.trace.span_id)

      assert span.status == :ok
      assert span.duration_ms == 1234
      assert span.doing == nil
    end

    test "a failed span settles as an error", %{tool: tool} do
      activity =
        Activity.new()
        |> fold(tool, %Event.SpanStarted{name: "deep_research"})
        |> fold(tool, %Event.SpanFinished{outcome: {:error, :timeout}, duration_ms: 50})

      assert Activity.fetch(activity, tool.trace.span_id).status == :error
    end

    test "the first close wins, because a reaped branch may close twice", %{tool: tool} do
      activity =
        Activity.new()
        |> fold(tool, %Event.SpanStarted{name: "slow"})
        |> fold(tool, %Event.SpanFinished{outcome: {:error, :crashed}, duration_ms: 10})
        |> fold(tool, %Event.SpanFinished{outcome: {:error, :timeout}, duration_ms: 999})

      span = Activity.fetch(activity, tool.trace.span_id)

      assert span.status == :error
      assert span.duration_ms == 10
    end

    test "a turn closes on its own events", %{turn: turn} do
      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]}, 100)
        |> fold(turn, %Event.TurnFinished{messages: []}, 350)

      span = Activity.fetch(activity, turn.trace.span_id)

      assert span.status == :ok
      assert span.duration_ms == 250
    end

    test "a failed turn closes as an error", %{turn: turn} do
      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})
        |> fold(turn, %Event.TurnFailed{reason: :rate_limited})

      assert Activity.fetch(activity, turn.trace.span_id).status == :error
    end
  end

  describe "what a span is doing" do
    test "follows the last thing it reported", %{turn: turn} do
      activity = Activity.new() |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})

      assert fold(activity, turn, %Event.ModelStarted{
               message_id: "m0",
               model_spec: :m,
               decided_by: %{by: :default, hooks: []}
             }).spans
             |> Map.fetch!(turn.trace.span_id)
             |> Map.fetch!(:doing) == "waiting on the model"

      assert fold(activity, turn, %Event.Thinking{text: "hmm"}).spans
             |> Map.fetch!(turn.trace.span_id)
             |> Map.fetch!(:doing) == "thinking"

      assert fold(activity, turn, %Event.Result{text: "yes"}).spans
             |> Map.fetch!(turn.trace.span_id)
             |> Map.fetch!(:doing) == "answering"
    end

    test "a finished model request is no longer doing anything", %{turn: turn} do
      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})
        |> fold(turn, %Event.ModelStarted{
          message_id: "m0",
          model_spec: :m,
          decided_by: %{by: :default, hooks: []}
        })
        |> fold(turn, %Event.ModelFinished{
          message_id: "m0",
          outcome: :ok,
          duration_ms: 12,
          answer: nil,
          cost: nil
        })

      assert Activity.fetch(activity, turn.trace.span_id).doing == nil
    end

    test "a payload it does not follow leaves the span alone", %{turn: turn} do
      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})
        |> fold(turn, %Event.Thinking{text: "hmm"})
        |> fold(turn, %Event.ToolCall{call: %ToolCall{id: "c1", name: "echo", arguments: %{}}})

      assert Activity.fetch(activity, turn.trace.span_id).doing == "thinking"
    end
  end

  describe "depth" do
    test "the root is zero and each level adds one", %{turn: turn, tool: tool} do
      branch = Source.child(tool, name: "pricing")

      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})
        |> fold(tool, %Event.SpanStarted{name: "deep_research"})
        |> fold(branch, %Event.SpanStarted{name: "pricing"})

      assert Activity.depth(activity, turn.trace.span_id) == 0
      assert Activity.depth(activity, tool.trace.span_id) == 1
      assert Activity.depth(activity, branch.trace.span_id) == 2
    end

    test "a span whose parent was never seen counts what it can", %{tool: tool} do
      activity = Activity.new() |> fold(tool, %Event.SpanStarted{name: "deep_research"})

      assert Activity.depth(activity, tool.trace.span_id) == 1
    end

    test "a span nobody has seen is at the root", %{turn: turn} do
      assert Activity.depth(Activity.new(), turn.trace.span_id) == 0
    end
  end

  describe "running" do
    setup %{turn: turn, tool: tool} do
      branch = Source.child(tool, name: "pricing")

      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})
        |> fold(tool, %Event.SpanStarted{name: "deep_research"})
        |> fold(branch, %Event.SpanStarted{name: "pricing"})

      {:ok, activity: activity, branch: branch}
    end

    test "lists only what is still going", %{activity: activity, branch: branch} do
      assert Enum.map(Activity.running(activity), & &1.name) ==
               ["turn", "deep_research", "pricing"]

      activity = fold(activity, branch, %Event.SpanFinished{outcome: :ok, duration_ms: 10})

      assert Enum.map(Activity.running(activity), & &1.name) == ["turn", "deep_research"]
    end

    test "the innermost running span is the deepest one", %{activity: activity, branch: branch} do
      assert Activity.innermost(activity).name == "pricing"

      activity = fold(activity, branch, %Event.SpanFinished{outcome: :ok, duration_ms: 10})

      assert Activity.innermost(activity).name == "deep_research"
    end

    test "nothing running has no innermost", %{turn: turn} do
      activity =
        Activity.new()
        |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]})
        |> fold(turn, %Event.TurnFinished{messages: []})

      assert Activity.running(activity) == []
      assert Activity.innermost(activity) == nil
    end
  end

  describe "elapsed_ms/2" do
    test "a running span counts from when it started", %{turn: turn} do
      activity =
        Activity.new() |> fold(turn, %Event.TurnStarted{messages: [Message.new("hi")]}, 100)

      assert Activity.fetch(activity, turn.trace.span_id) |> Activity.elapsed_ms(450) == 350
    end

    test "a settled span reports what it took, whatever the clock says", %{tool: tool} do
      activity =
        Activity.new()
        |> fold(tool, %Event.SpanStarted{name: "echo"}, 100)
        |> fold(tool, %Event.SpanFinished{outcome: :ok, duration_ms: 25}, 450)

      assert Activity.fetch(activity, tool.trace.span_id) |> Activity.elapsed_ms(9_999) == 25
    end
  end
end
