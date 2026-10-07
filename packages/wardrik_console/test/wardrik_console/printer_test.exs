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
    assert print([{:result, "# Tri"}, {:result, "age\nsome **bold"}]) == ["Triage"]

    assert print([{:result, "# Triage\nsome **bold**"}, {:turn_finished, []}]) == [
             "Triage",
             "some bold"
           ]
  end

  test "reasoning is faint behind a bar, and settled before the answer that follows it" do
    {lines, _printer} = lines([{:thinking, "hmm"}, {:result, "answer\n"}], Printer.new())

    assert Enum.map(lines, &plain/1) == ["┊ hmm", "answer"]
    assert :faint in sequences(hd(lines))
  end

  test "text from work the turn delegated is not shown" do
    nested = Source.child(root())

    assert print([
             Event.new(nested, {:result, "from a subagent\n"}),
             Event.new(nested, {:thinking, "its thinking\n"})
           ]) == []
  end

  test "a tool call is a line when it starts and when it ends, after the text before it" do
    assert print([
             {:result, "Looking"},
             {:tool_started, "call_1", "github/search", %{"q" => "flaky"}, "key"},
             {:tool_finished, "call_1", "github/search", {:ok, "3 issues"}},
             {:tool_started, "call_2", "clock", %{}, "key"},
             {:tool_finished, "call_2", "clock", {:error, :timeout}},
             {:tool_denied, "call_3", "shell", "Not on a Friday."}
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
        [{:tool_denied, "call_1", "shell", String.duplicate("x", 50)}],
        Printer.new(width: 30)
      )

    assert String.length(line) == 30
    assert String.ends_with?(line, "…")
  end

  test "why a turn failed is written whole, however long" do
    reason = {:provider_build_failed, String.duplicate("x", 60)}
    [line] = print([{:turn_failed, reason}], Printer.new(width: 30))

    assert line == "✗ the turn failed: #{inspect(reason)}"
  end

  test "a turn waiting on a person says what for, each call with its id" do
    calls = [
      {%{id: "call_1", name: "github/create_issue", arguments: %{}}, "This opens an issue."},
      {%{id: "call_2", name: "shell", arguments: %{}}, "This runs a command."}
    ]

    assert print([{:turn_parked, calls}]) == [
             "Waiting on a person for 2 calls:",
             "  ? github/create_issue  call_1  This opens an issue.",
             "  ? shell  call_2  This runs a command."
           ]

    assert print([{:turn_parked, Enum.take(calls, 1)}]) |> hd() ==
             "Waiting on a person for 1 call:"
  end

  test "a turn that fails or is stopped says so after what it had written" do
    assert print([{:result, "half"}, {:turn_failed, :rate_limited}]) == [
             "half",
             "✗ the turn failed: :rate_limited"
           ]

    assert print([{:turn_interrupted, %{}}]) == ["■ stopped"]
  end

  test "a table is laid out at the printer's width once it ends" do
    [top | _rest] =
      lines =
      print(
        [{:result, "| a | b |\n|---|---|\n| one two three | 4 |\n"}, {:turn_finished, []}],
        Printer.new(width: 16)
      )

    assert String.starts_with?(top, "╭")
    assert Enum.all?(lines, &(String.length(&1) <= 16))
  end

  test "events that say nothing return no lines" do
    assert print([{:chunk, "c"}, {:meta, %{}}, {:tool_call, %{}}, {:span_started, "x"}]) == []
  end
end
