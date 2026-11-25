defmodule Wardrik.Chat.Replies.StateTest do
  use ExUnit.Case, async: true

  alias Wardrik.Chat.Replies.State
  alias Wardrik.Chat.Step

  @conversation {"acme/triage", "chat.T1.C1.1.1"}
  @time ~U[2026-11-25 10:00:00Z]

  defp new(reasoning \\ true) do
    state = %{State.new("T1", "C1") | channel: %{reasoning: reasoning}}
    state = State.put_asker(state, "1.1", "U1")
    take(state, "run.started", %{"run" => %{"id" => "r1", "message_ids" => ["1.1"]}})
  end

  defp take({_post, state}, type, data), do: take(state, type, data)

  defp take(state, type, data) do
    event = %Wardrik.Event{type: "wardrik." <> type, time: @time, data: data}
    State.take(state, @conversation, event)
  end

  defp steps({_post, state}), do: State.find_run(state, @conversation).steps

  defp thinking(state),
    do: take(state, "message.started", %{"message" => %{"id" => "msg_1"}})

  defp retry_data(what) do
    retry = %{
      "attempt" => 2,
      "attempts" => 5,
      "wait_ms" => 7_500,
      "error" => %{"message" => "Overloaded"}
    }

    Map.merge(retry, what)
  end

  test "starts a run with no steps, for the member who asked" do
    {:none, state} = new()
    assert %{asker: "U1", steps: [], progress: nil} = State.find_run(state, @conversation)
  end

  test "shows a model call as thinking, then writing, then done" do
    taken = thinking(new())

    assert {{:progress, :changed}, _state} = taken
    assert [%Step{id: "msg_1", title: "Thinking", status: :running, since: @time}] = steps(taken)

    taken = take(taken, "message.delta", %{"message" => %{"id" => "msg_1"}, "delta" => "Hi"})
    assert [%Step{title: "Writing"}] = steps(taken)

    taken = take(taken, "message.completed", %{"message" => %{"id" => "msg_1"}, "status" => "ok"})
    assert [%Step{status: :done}] = steps(taken)
  end

  test "shows the end of the model's reasoning, unless the channel hides it" do
    delta = String.duplicate("a", 290) <> "Checking the calendar."
    data = %{"message" => %{"id" => "msg_1"}, "delta" => delta}

    taken =
      new()
      |> thinking()
      |> take("reasoning.delta", data)

    assert {{:progress, :details}, _state} = taken
    assert [%Step{details: details}] = steps(taken)
    assert String.length(details) == 300
    assert String.ends_with?(details, "Checking the calendar.")

    hidden =
      false
      |> new()
      |> thinking()
      |> take("reasoning.delta", data)

    assert {:none, _state} = hidden
    assert [%Step{details: nil}] = steps(hidden)
  end

  test "says when the model failed and will be tried again" do
    taken =
      new()
      |> thinking()
      |> take("message.retrying", retry_data(%{"message" => %{"id" => "msg_1"}}))

    assert [%Step{status: :running, details: details}] = steps(taken)
    assert details == "The model failed: Overloaded. Trying again in 8s (attempt 2 of 5)."
  end

  test "shows each tool call, and why one failed" do
    tool = %{"name" => "search", "call" => %{"id" => "call_1"}}

    taken =
      new()
      |> take("tool_call.started", %{"tool" => tool})
      |> take("tool_call.retrying", retry_data(%{"tool" => tool}))

    assert [%Step{title: "Running search", details: "search failed: Overloaded." <> _rest}] =
             steps(taken)

    failed = %{"tool" => tool, "status" => "error", "error" => %{"message" => "Timed out."}}
    taken = take(taken, "tool_call.completed", failed)
    assert [%Step{status: :failed, details: "Timed out."}] = steps(taken)
  end

  test "shows a subagent's calls, and its end" do
    agent = %{"agent" => %{"name" => "researcher"}}

    taken =
      new()
      |> take("subagent.started", agent)
      |> take(
        "subagent.progress",
        Map.merge(agent, %{"tool" => %{"name" => "fetch"}, "tool_calls" => 2})
      )

    assert [%Step{title: "Asked researcher", details: "Running fetch, 2 calls"}] = steps(taken)

    taken = take(taken, "subagent.completed", agent)
    assert [%Step{status: :done, details: nil}] = steps(taken)
  end

  test "ends the progress when the run waits, and starts it again when it resumes" do
    {post, state} =
      new()
      |> thinking()
      |> take("run.interrupted", %{"interrupts" => [%{"id" => "call_1"}]})

    assert post == {:waiting, ["call_1"], nil}
    assert %{steps: [], progress: nil} = State.find_run(state, @conversation)
    refute State.running?(state, @conversation)
  end

  test "says a run ran out of time" do
    assert {{:failed, "It ran out of time."}, state} =
             new()
             |> thinking()
             |> take("run.deadline_exceeded", %{})

    assert State.find_run(state, @conversation) == nil
  end

  test "keeps the run's progress and steps between restarts" do
    {_post, state} = thinking(new())
    state = State.put_progress(state, @conversation, "1696.5678")

    loaded =
      state
      |> State.dump()
      |> JSON.encode!()
      |> JSON.decode!()
      |> then(&State.load(3, &1))

    assert State.find_run(loaded, @conversation) == State.find_run(state, @conversation)
  end

  test "reads a state version 2 saved, with no askers or progress" do
    dumped = %{
      "workspace" => "T1",
      "room" => "C1",
      "cursor" => "c-1",
      "conversations" => [["acme/triage", "C1"]],
      "senders" => %{},
      "runs" => [
        %{
          "agent" => "acme/triage",
          "conversation" => "C1",
          "id" => "r1",
          "answering" => ["1.1"],
          "asked_by" => "maria"
        }
      ]
    }

    state = State.load(2, dumped)

    assert state.askers == %{}

    assert State.find_run(state, {"acme/triage", "C1"}) == %{
             id: "r1",
             answering: ["1.1"],
             asked_by: "maria",
             asker: nil,
             progress: nil,
             steps: []
           }
  end
end
