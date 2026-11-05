defmodule WardrikDaemon.Console.PrinterTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.Console.Ansi
  alias WardrikDaemon.Console.Printer

  defp printed(events, width \\ 80) do
    {lines, _printer} =
      Enum.flat_map_reduce(events, Printer.new(width: width), fn event, printer ->
        Printer.event(printer, event)
      end)

    Enum.map(lines, &IO.chardata_to_string(Ansi.chardata(&1, false)))
  end

  defp event(type, data), do: %{"type" => "wardrik." <> type, "data" => data}
  defp delta(type, text), do: event(type, %{"delta" => text})

  test "shows reasoning faint behind a bar, set off by a line each side, a line once it's whole" do
    assert printed([
             delta("reasoning.delta", "Look at "),
             delta("reasoning.delta", "the queue.\n"),
             delta("reasoning.delta", "Then count.\n")
           ]) ==
             ["", "┊ Look at the queue.", "┊ Then count."]

    assert printed([delta("message.delta", "**Two** cases")]) == []

    assert printed([
             delta("reasoning.delta", "Count them"),
             delta("message.delta", "Two cases.\n- one\n"),
             event("run.completed", %{})
           ]) == ["", "┊ Count them", "", "Two cases.", "• one"]

    tool = %{"name" => "echo", "call" => %{"id" => "c1", "arguments" => %{}}}

    assert printed([
             delta("reasoning.delta", "Echo it.\n"),
             event("tool_call.started", %{"tool" => tool})
           ]) == ["", "┊ Echo it.", "", "  → echo"]

    ["", faint] =
      [delta("reasoning.delta", "Hm.\n")]
      |> Enum.flat_map_reduce(Printer.new(), &Printer.event(&2, &1))
      |> elem(0)

    assert IO.chardata_to_string(Ansi.chardata(faint, true)) =~ "\e[2m"
  end

  test "says each tool call as it starts and ends, cut to the width" do
    tool = %{"name" => "web_search", "call" => %{"id" => "c1", "arguments" => %{"q" => "elixir"}}}

    assert printed([
             event("tool_call.started", %{"tool" => tool}),
             event("tool_call.completed", %{"tool" => tool, "status" => "ok"}),
             event("tool_call.completed", %{
               "tool" => tool,
               "status" => "error",
               "error" => %{"message" => "down"}
             }),
             event("tool_call.denied", %{"tool" => tool, "reason" => "No."})
           ]) == [
             ~s(  → web_search {"q":"elixir"}),
             "  ✓ web_search",
             "  ✗ web_search: down",
             "  ✗ web_search was refused: No."
           ]

    assert [cut] = printed([event("tool_call.started", %{"tool" => tool})], 12)
    assert String.length(cut) <= 12
  end

  test "lays a markdown table out, and says what a turn waits on and how it ended" do
    lines = printed([delta("message.delta", "| a | b |\n|---|---|\n| 1 | 2 |\nafter\n")])
    assert Enum.any?(lines, &(&1 =~ "│ 1"))
    assert List.last(lines) == "after"

    interrupts = [
      %{"id" => "c1", "name" => "echo", "message" => "Echo?"},
      %{"id" => "c2", "message" => "Over budget.", "labels" => ["outside"]}
    ]

    assert printed([event("run.interrupted", %{"interrupts" => interrupts})]) == [
             "Waiting on a person for 2 calls:",
             "  ? echo  c1  Echo?",
             "  ? the model  c2  Over budget.  (after content from outside)"
           ]

    assert printed([event("run.failed", %{"error" => %{"message" => "boom"}})]) ==
             ["✗ the turn failed: boom"]

    assert printed([event("run.cancelled", %{})]) == ["■ stopped"]

    assert printed([event("run.deadline_exceeded", %{})]) == [
             "■ stopped: it ran past its timeout"
           ]

    assert printed([
             event("conversation.compacted", %{"messages_before" => 9, "messages_after" => 3})
           ]) ==
             ["  · compacted the history, 9 messages to 3"]

    retry = %{
      "wait_ms" => 2000,
      "attempt" => 1,
      "attempts" => 3,
      "error" => %{"message" => "429"}
    }

    assert printed([event("message.retrying", retry)]) == [
             "  ↻ model failed: 429, again in 2s (1 of 3)"
           ]

    message = %{
      "message" => %{"parts" => [%{"type" => "text", "content" => "Hi"}]},
      "sender" => %{"id" => "acme/@jon"}
    }

    assert printed([event("message.created", message)]) == ["› acme/@jon: Hi"]
    assert printed([event("run.started", %{}), %{"type" => "other"}]) == []
  end
end
