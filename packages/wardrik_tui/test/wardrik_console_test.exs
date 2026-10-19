defmodule WardrikConsoleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Wardrik.Event
  alias Wardrik.Test.Events
  alias Wardrik.Test.Fleet
  alias WardrikConsole, as: Console

  # The console inherits the group leader of whoever starts it, so it has to be
  # started inside the capture block. `:sys.get_state/1` then flushes its
  # mailbox before the capture ends.
  defp render(agent_id, events) do
    capture_io(fn ->
      {:ok, console} = Console.start_link(agent_id: agent_id)
      Enum.each(events, &Events.emit(agent_id, &1))
      :sys.get_state(console)
    end)
  end

  test "prints each line an event completes" do
    output =
      render(Fleet.id(), [
        %Event.Thinking{text: "hmm"},
        %Event.Result{text: "the answer"},
        %Event.ToolStarted{
          call_id: "call_1",
          name: "echo",
          arguments: %{},
          idempotency_key: "key",
          decided_by: %{by: :default, hooks: []}
        },
        %Event.ToolFinished{
          call_id: "call_1",
          name: "echo",
          result: {:ok, "done"},
          served_by: nil,
          cost: nil
        },
        %Event.TurnFailed{reason: :rate_limited}
      ])

    assert output ==
             "┊ hmm\nthe answer\n  → echo\n  ✓ echo\n✗ the turn failed: :rate_limited\n"
  end

  test "ignores events it does not render" do
    output =
      render(Fleet.id(), [
        %Event.ToolCall{call: %Wardrik.Conversation.ToolCall{id: "c", name: "n", arguments: %{}}}
      ])

    assert output == ""
  end

  test "only receives its own agent's events" do
    mine = Fleet.id()
    theirs = Fleet.id()

    output =
      capture_io(fn ->
        {:ok, console} = Console.start_link(agent_id: mine)
        Events.emit(theirs, %Event.Result{text: "not mine\n"})
        Events.emit(mine, %Event.Result{text: "mine\n"})
        :sys.get_state(console)
      end)

    assert output == "mine\n"
  end

  test "lays lines out to the width it is given, and ignores what is not an event" do
    agent_id = Fleet.id()

    output =
      capture_io(fn ->
        {:ok, console} = Console.start_link(agent_id: agent_id, width: 20)
        send(console, :not_an_event)

        Events.emit(
          agent_id,
          %Event.ToolDenied{
            call_id: "call_1",
            name: "shell",
            reason: String.duplicate("x", 40),
            decided_by: %{by: :default, hooks: []}
          }
        )

        :sys.get_state(console)
      end)

    assert output == "  ✗ shell was refus…\n"
  end
end
