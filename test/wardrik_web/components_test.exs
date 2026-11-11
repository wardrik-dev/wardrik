defmodule WardrikWeb.ComponentsTest do
  use ExUnit.Case, async: true

  import WardrikWeb.Components

  test "says what an agent is doing" do
    tool = %{"name" => "github__create_issue"}

    for {event, text} <- [
          {%{"type" => "wardrik.run.interrupted", "interrupts" => [%{}]},
           "Waiting for approval of 1 tool call"},
          {%{"type" => "wardrik.run.interrupted", "interrupts" => [%{}, %{}]},
           "Waiting for approval of 2 tool calls"},
          {%{"type" => "wardrik.message.retrying", "attempt" => 2, "attempts" => 3},
           "Retrying the model call (attempt 2 of 3)"},
          {%{"type" => "wardrik.tool_call.retrying", "tool" => tool},
           "Retrying github__create_issue"},
          {%{"type" => "wardrik.tool_call.started", "tool" => tool},
           "Calling github__create_issue"},
          {%{"type" => "wardrik.tool_call.completed", "tool" => tool},
           "Finished github__create_issue"},
          {%{"type" => "wardrik.tool_call.denied", "tool" => tool},
           "github__create_issue was denied"},
          {%{"type" => "wardrik.step.started", "step" => %{"name" => "plan"}},
           "Running step plan"},
          {%{"type" => "wardrik.message.started"}, "Generating a response"},
          {%{"type" => "wardrik.run.resumed"}, "Resuming a run"},
          {%{"type" => "wardrik.run.started"}, "Starting a run"},
          {%{"type" => "wardrik.run.settled"}, "run.settled"}
        ],
        do: assert(doing_text(event) == text)
  end

  test "previews an event's data from its first values" do
    data = %{"b" => [1, true, nil], "a" => %{"text" => "hello", "empty" => ""}, "c" => "skip"}
    assert preview(data) == "hello · 1 · true"
    assert preview(data, "hello") == "1 · true · skip"
  end

  test "formats numbers, costs, durations and times" do
    assert usd(nil) == "—"
    assert usd(0) == "$0"
    assert usd(0.004) == "$0.0040"
    assert usd(1.5) == "$1.50"
    assert micro_usd(nil) == "—"
    assert number(nil) == "—"
    assert number(1_234_567) == "1,234,567"
    assert tokens(nil) == "—"
    assert tokens(8400) == "8.4k"
    assert bytes(nil) == "—"
    assert bytes(512) == "512 B"
    assert bytes(1_843_200) == "1.8 MB"
    assert bytes(98_566_144) == "94 MB"
    assert bytes(5 * 1024 ** 5) == "5120 TB"
    assert took(850) == "850 ms"
    assert took(190_000) == "3m 10s"
    assert took(60_000) == "1m"
    assert took(590_400_000) == "6d 20h"

    now = ~U[2026-11-10 18:00:00Z]
    assert ago(nil, now) == "—"
    assert ago("not a time", now) == "not a time"
    assert ago("2026-11-10T17:59:58Z", now) == "just now"
    assert ago("2026-11-10T18:05:00Z", now) == "in 5m"
    assert ago("2026-11-10T17:59:30Z", now) == "30s ago"
    assert ago("2026-11-10T15:00:00Z", now) == "3h ago"
    assert ago("2026-11-08T18:00:00Z", now) == "2d ago"
  end
end
