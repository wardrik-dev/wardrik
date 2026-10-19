defmodule WardrikChannel.Replies.StateTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias WardrikChannel.Replies.State

  @agent AgentID.parse!("acme/books/C1-1.1")

  defp followed(cursor \\ ""),
    do: State.follow(State.new("chat", "T1", "C1"), "1.1", @agent, cursor)

  defp event(sequence, type, data), do: %{"sequence" => sequence, "type" => type, "data" => data}

  # What the thread's next event asks to be posted, with a cursor past it
  # named for its sequence.
  defp take(state, event), do: State.take(state, "1.1", event, "past-#{event["sequence"]}")

  defp run(id), do: %{"id" => id}

  defp said(text),
    do: %{"role" => "assistant", "parts" => [%{"type" => "text", "content" => text}]}

  test "answers what a run said last, with the messages it answers" do
    started =
      event(1, "wardrik.run.started", %{"run" => %{"id" => "r1", "message_ids" => ["m1"]}})

    {:none, state} = take(followed(), started)

    called = %{"role" => "assistant", "parts" => [%{"type" => "tool_call", "id" => "c1"}]}

    completed =
      event(2, "wardrik.run.completed", %{
        "run" => run("r1"),
        "messages" => [said("Looking."), called, said("Two cases.")]
      })

    assert {{:reply, "Two cases.", ["m1"]}, state} = take(state, completed)
    assert state.threads["1.1"].cursor == "past-2"
    assert state.threads["1.1"].runs == %{}

    silent = event(3, "wardrik.run.completed", %{"run" => run("r2"), "messages" => [called]})
    assert {{:reply, "", []}, _state} = take(state, silent)
  end

  test "says a run cancelled stopped, with the messages it answers, and nothing for the rest" do
    started =
      event(1, "wardrik.run.started", %{"run" => %{"id" => "r1", "message_ids" => ["m1"]}})

    {:none, state} = take(followed(), started)

    cancelled = event(2, "wardrik.run.cancelled", %{"run" => run("r1")})
    assert {{:stopped, ["m1"]}, state} = take(state, cancelled)
    assert state.threads["1.1"].runs == %{}

    assert {:none, state} = take(state, event(3, "wardrik.message.created", %{}))
    assert state.threads["1.1"].cursor == "past-3"
  end

  test "asks for the calls a run waits on, and says why one failed" do
    interrupted =
      event(1, "wardrik.run.interrupted", %{"run" => run("r1"), "interrupts" => [%{"id" => "c1"}]})

    assert {{:parked, ["c1"]}, state} = take(followed(), interrupted)

    failed =
      event(2, "wardrik.run.failed", %{"run" => run("r1"), "error" => %{"message" => "Locked."}})

    assert {{:failed, "Locked."}, _state} = take(state, failed)
  end

  test "says an account a call waited on was connected" do
    connected =
      event(1, "wardrik.interrupt.resolved", %{
        "interrupt" => %{"id" => "c1"},
        "decision" => "approved",
        "resolved_by" => %{"id" => "oauth:github", "name" => "github authorization"}
      })

    assert {{:connected, "github"}, _state} = take(followed(), connected)
  end

  defp decided(decision, by, said \\ nil) do
    data = %{"interrupt" => %{"id" => "c1"}, "decision" => decision, "resolved_by" => by}
    key = if decision == "approved", do: "note", else: "reason"
    data = if said, do: Map.put(data, key, said), else: data
    {post, _state} = take(followed(), event(1, "wardrik.interrupt.resolved", data))
    post
  end

  test "says who decided a call, and what they said with it" do
    maria = %{"id" => "slack:U1", "name" => "maria"}
    jon = %{"id" => "acme/@jon"}

    assert decided("approved", maria) == {:decided, "Approved by maria."}
    assert decided("approved", jon) == {:decided, "Approved by acme/@jon."}

    assert decided("approved", jon, "Only this once.") ==
             {:decided, "Approved by acme/@jon: Only this once."}

    assert decided("rejected", jon) == {:decided, "Denied by acme/@jon."}

    assert decided("rejected", jon, "Not on Fridays.") ==
             {:decided, "Denied by acme/@jon: Not on Fridays."}

    assert decided("rejected", maria, "Denied in Slack by maria: Staging first.") ==
             {:decided, "Denied in Slack by maria: Staging first."}

    assert {:none, _state} =
             take(followed(), event(1, "wardrik.interrupt.resolved", %{"decision" => "approved"}))
  end

  test "follows a thread once, from where it was first followed" do
    state = followed("seven")
    assert State.followed?(state, "1.1")
    refute State.followed?(state, "2.1")
    assert State.follow(state, "1.1", @agent, "twenty").threads["1.1"].cursor == "seven"
  end
end
