defmodule WardrikDaemon.CLI.StatusTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.CLI.Status
  alias WardrikDaemon.CLI.Terminal

  defp status(now \\ 0, opts \\ []), do: Status.new(%Terminal{live: :screen}, now, opts)

  defp text(status, now) do
    status
    |> Status.line(now)
    |> Owl.Data.untag()
    |> to_string()
  end

  defp event(type, data), do: %{"type" => "wardrik." <> type, "data" => data}

  defp tool(id, name), do: %{"tool" => %{"name" => name, "call" => %{"id" => id}}}

  test "is nil without a live screen" do
    assert Status.new(%Terminal{}, 0) == nil
  end

  test "says what the turn does, and for how long" do
    assert text(status(), 4_200) == "⠋ thinking · 4s"

    writing = Status.seen(status(), event("message.delta", %{"delta" => "Hi"}), 0)
    assert text(writing, 0) =~ "writing"

    running =
      status()
      |> Status.seen(event("tool_call.started", tool("c1", "web_search")), 0)
      |> Status.seen(event("tool_call.started", tool("c2", "fetch")), 0)

    assert text(running, 0) =~ "fetch and 1 more"

    one = Status.seen(running, event("tool_call.completed", tool("c2", "fetch")), 0)
    assert text(one, 0) =~ "web_search"

    done = Status.seen(one, event("tool_call.completed", tool("c1", "web_search")), 0)
    assert text(done, 0) =~ "thinking"

    retrying = Status.seen(done, event("message.retrying", %{}), 0)
    assert text(retrying, 0) =~ "trying the model again"
  end

  test "says it hasn't started, and keeps to one row" do
    waiting = status(0, doing: "waiting for triage to start")
    assert text(waiting, 12_000) == "⠋ waiting for triage to start · 12s"

    started = Status.seen(waiting, event("run.started", %{"run" => %{}}), 12_000)
    assert text(started, 13_000) == "⠋ thinking · 1s"

    many =
      Enum.reduce(
        1..30,
        started,
        &Status.seen(&2, event("tool_call.started", tool("c#{&1}", "a_long_tool_name")), 13_000)
      )

    line = text(many, 13_000)
    assert String.length(line) <= 79
  end

  test "says it's idle between turns, and times a turn from its start" do
    idle = status(nil, idle: "Following triage. Ctrl-C stops.")
    assert text(idle, 9_000) == "· Following triage. Ctrl-C stops."

    started = Status.seen(idle, event("run.started", %{"run" => %{}}), 1_000)
    assert text(started, 3_000) == "⠋ thinking · 2s"

    ended = Status.seen(started, event("run.completed", %{}), 3_000)
    assert text(ended, 4_000) == "· Following triage. Ctrl-C stops."
  end
end
