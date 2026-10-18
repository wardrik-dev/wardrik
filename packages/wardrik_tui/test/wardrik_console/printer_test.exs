defmodule WardrikConsole.PrinterTest do
  use ExUnit.Case, async: true

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias Wardrik.Event
  alias Wardrik.Event.Source
  alias WardrikConsole.Printer

  defp plain(data), do: data |> Owl.Data.untag() |> IO.chardata_to_string()

  defp sequences(%Owl.Tag{sequences: sequences, data: data}), do: sequences ++ sequences(data)
  defp sequences(list) when is_list(list), do: Enum.flat_map(list, &sequences/1)
  defp sequences(_other), do: []

  defp root, do: Source.root(~A"acme/@jon/triage")

  # Every payload through one printer, on the turn's own span unless given
  # events, and the lines they returned as plain text.
  defp print(payloads, printer \\ Printer.new()) do
    {lines, _printer} = lines(payloads, printer)
    Enum.map(lines, &plain/1)
  end

  defp lines(payloads, printer) do
    Enum.flat_map_reduce(payloads, printer, fn
      %Event{} = event, printer -> Printer.event(printer, event)
      payload, printer -> Printer.event(printer, Event.new(root(), payload))
    end)
  end

  test "the answer is returned a line at a time, as markdown, and the rest when the turn ends" do
    assert print([%Event.Result{text: "# Tri"}, %Event.Result{text: "age\nsome **bold"}]) == [
             "Triage"
           ]

    assert print([
             %Event.Result{text: "# Triage\nsome **bold**"},
             %Event.TurnFinished{messages: []}
           ]) == [
             "Triage",
             "some bold"
           ]
  end

  test "reasoning is faint behind a bar, and settled before the answer that follows it" do
    {lines, _printer} =
      lines([%Event.Thinking{text: "hmm"}, %Event.Result{text: "answer\n"}], Printer.new())

    assert Enum.map(lines, &plain/1) == ["┊ hmm", "answer"]
    assert :faint in sequences(hd(lines))
  end

  test "text from work the turn delegated is not shown" do
    nested = Source.child(root())

    assert print([
             Event.new(nested, %Event.Result{text: "from a subagent\n"}),
             Event.new(nested, %Event.Thinking{text: "its thinking\n"})
           ]) == []
  end

  test "a tool call is a line when it starts and when it ends, after the text before it" do
    assert print([
             %Event.Result{text: "Looking"},
             %Event.ToolStarted{
               call_id: "call_1",
               name: "github/search",
               arguments: %{"q" => "flaky"},
               idempotency_key: "key",
               decided_by: %{by: :default, hooks: []}
             },
             %Event.ToolFinished{
               call_id: "call_1",
               name: "github/search",
               result: {:ok, "3 issues"},
               served_by: nil,
               cost: nil
             },
             %Event.ToolStarted{
               call_id: "call_2",
               name: "clock",
               arguments: %{},
               idempotency_key: "key",
               decided_by: %{by: :default, hooks: []}
             },
             %Event.ToolFinished{
               call_id: "call_2",
               name: "clock",
               result: {:error, :timeout},
               served_by: nil,
               cost: nil
             },
             %Event.ToolDenied{
               call_id: "call_3",
               name: "shell",
               reason: "Not on a Friday.",
               decided_by: %{by: :default, hooks: []}
             }
           ]) == [
             "Looking",
             ~s(  → github/search {"q":"flaky"}),
             "  ✓ github/search",
             "  → clock",
             "  ✗ clock: :timeout",
             "  ✗ shell was refused: Not on a Friday."
           ]
  end

  test "a line longer than the width is cut short" do
    [line] =
      print(
        [
          %Event.ToolDenied{
            call_id: "call_1",
            name: "shell",
            reason: String.duplicate("x", 50),
            decided_by: %{by: :default, hooks: []}
          }
        ],
        Printer.new(width: 30)
      )

    assert String.length(line) == 30
    assert String.ends_with?(line, "…")
  end

  test "why a turn failed is written whole, however long" do
    reason = {:provider_build_failed, String.duplicate("x", 60)}
    [line] = print([%Event.TurnFailed{reason: reason}], Printer.new(width: 30))

    assert line == "✗ the turn failed: #{inspect(reason)}"
  end

  test "a turn waiting on a person says what for, each call with its id" do
    calls = [
      {%{id: "call_1", name: "github/create_issue", arguments: %{}}, "This opens an issue."},
      {%{id: "call_2", name: "shell", arguments: %{}}, "This runs a command."}
    ]

    assert print([%Event.TurnParked{calls: calls}]) == [
             "Waiting on a person for 2 calls:",
             "  ? github/create_issue  call_1  This opens an issue.",
             "  ? shell  call_2  This runs a command."
           ]

    assert print([%Event.TurnParked{calls: Enum.take(calls, 1)}]) |> hd() ==
             "Waiting on a person for 1 call:"
  end

  test "a turn that fails or is stopped says so after what it had written" do
    assert print([%Event.Result{text: "half"}, %Event.TurnFailed{reason: :rate_limited}]) == [
             "half",
             "✗ the turn failed: :rate_limited"
           ]

    assert print([%Event.TurnInterrupted{stats: %{}}]) == ["■ stopped"]
  end

  test "a table is laid out at the printer's width once it ends" do
    [top | _rest] =
      lines =
      print(
        [
          %Event.Result{text: "| a | b |\n|---|---|\n| one two three | 4 |\n"},
          %Event.TurnFinished{messages: []}
        ],
        Printer.new(width: 16)
      )

    assert String.starts_with?(top, "╭")
    assert Enum.all?(lines, &(String.length(&1) <= 16))
  end

  test "events that say nothing return no lines" do
    assert print([
             %Event.Chunk{chunk: "c"},
             %Event.Meta{chunk: %{}},
             %Event.ToolCall{call: %{}},
             %Event.SpanStarted{name: "x"}
           ]) == []
  end
end
