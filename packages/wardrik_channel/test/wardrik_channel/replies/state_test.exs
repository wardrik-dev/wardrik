defmodule WardrikChannel.Replies.StateTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias WardrikChannel.Replies.State

  @agent AgentID.parse!("acme/books/C1-1.1")

  defp followed(through \\ 0),
    do: State.follow(State.new("chat", "T1", "C1"), "1.1", @agent, through)

  defp event(sequence, type, data),
    do: %{
      "sequence" => String.pad_leading("#{sequence}", 12, "0"),
      "type" => type,
      "data" => data
    }

  defp run(id), do: %{"id" => id}

  defp said(text),
    do: %{"role" => "assistant", "parts" => [%{"type" => "text", "content" => text}]}

  test "answers what a run said last, with the messages it answers" do
    started =
      event(1, "wardrik.run.started", %{"run" => %{"id" => "r1", "message_ids" => ["m1"]}})

    {:none, state} = State.take(followed(), "1.1", started)

    called = %{"role" => "assistant", "parts" => [%{"type" => "tool_call", "id" => "c1"}]}

    completed =
      event(2, "wardrik.run.completed", %{
        "run" => run("r1"),
        "messages" => [said("Looking."), called, said("Two cases.")]
      })

    assert {{:reply, "Two cases.", ["m1"]}, state} = State.take(state, "1.1", completed)
    assert state.threads["1.1"].through == 2
    assert state.threads["1.1"].runs == %{}

    silent = event(3, "wardrik.run.completed", %{"run" => run("r2"), "messages" => [called]})
    assert {{:reply, "", []}, _state} = State.take(state, "1.1", silent)
  end

  test "says a run cancelled stopped, with the messages it answers, and nothing for the rest" do
    started =
      event(1, "wardrik.run.started", %{"run" => %{"id" => "r1", "message_ids" => ["m1"]}})

    {:none, state} = State.take(followed(), "1.1", started)

    cancelled = event(2, "wardrik.run.cancelled", %{"run" => run("r1")})
    assert {{:stopped, ["m1"]}, state} = State.take(state, "1.1", cancelled)
    assert state.threads["1.1"].runs == %{}

    assert {:none, state} = State.take(state, "1.1", event(3, "wardrik.message.created", %{}))
    assert state.threads["1.1"].through == 3
  end

  test "asks for the calls a run waits on, and says why one failed" do
    interrupted =
      event(1, "wardrik.run.interrupted", %{"run" => run("r1"), "interrupts" => [%{"id" => "c1"}]})

    assert {{:parked, ["c1"]}, state} = State.take(followed(), "1.1", interrupted)

    failed =
      event(2, "wardrik.run.failed", %{"run" => run("r1"), "error" => %{"message" => "Locked."}})

    assert {{:failed, "Locked."}, _state} = State.take(state, "1.1", failed)
  end

  test "says an account a call waited on was connected" do
    connected =
      event(1, "wardrik.interrupt.resolved", %{
        "interrupt" => %{"id" => "c1"},
        "decision" => "approved",
        "resolved_by" => %{"type" => "oauth", "id" => "github", "name" => "github authorization"}
      })

    assert {{:connected, "github"}, _state} = State.take(followed(), "1.1", connected)
  end

  defp decided(decision, by, said \\ nil) do
    data = %{"interrupt" => %{"id" => "c1"}, "decision" => decision, "resolved_by" => by}
    key = if decision == "approved", do: "note", else: "reason"
    data = if said, do: Map.put(data, key, said), else: data
    {post, _state} = State.take(followed(), "1.1", event(1, "wardrik.interrupt.resolved", data))
    post
  end

  test "says who decided a call, and what they said with it" do
    maria = %{"type" => "channel", "id" => "slack/U1", "name" => "maria"}
    jon = %{"type" => "user", "id" => "jon"}

    assert decided("approved", maria) == {:decided, "Approved by maria."}
    assert decided("approved", jon) == {:decided, "Approved by jon."}

    assert decided("approved", jon, "Only this once.") ==
             {:decided, "Approved by jon: Only this once."}

    assert decided("rejected", jon) == {:decided, "Denied by jon."}

    assert decided("rejected", jon, "Not on Fridays.") ==
             {:decided, "Denied by jon: Not on Fridays."}

    assert decided("rejected", maria, "Denied in Slack by maria: Staging first.") ==
             {:decided, "Denied in Slack by maria: Staging first."}

    assert {:none, _state} =
             State.take(
               followed(),
               "1.1",
               event(1, "wardrik.interrupt.resolved", %{"decision" => "approved"})
             )
  end

  test "follows a thread once, from where it was first followed" do
    state = followed(7)
    assert State.followed?(state, "1.1")
    refute State.followed?(state, "2.1")
    assert State.thread_of(state, @agent) == "1.1"
    assert State.thread_of(state, AgentID.parse!("acme/books")) == nil

    assert State.follow(state, "1.1", @agent, 20).threads["1.1"].through == 7
  end

  test "skips past what a log no longer holds, never back" do
    assert State.skip(followed(3), "1.1", 10).threads["1.1"].through == 9
    assert State.skip(followed(30), "1.1", 10).threads["1.1"].through == 30
  end
end
