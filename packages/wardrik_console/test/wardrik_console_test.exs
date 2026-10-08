defmodule WardrikConsoleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

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
        {:thinking, "hmm"},
        {:result, "the answer"},
        {:tool_started, "call_1", "echo", %{}, "key", %{by: :default, hooks: []}},
        {:tool_finished, "call_1", "echo", {:ok, "done"}, nil},
        {:turn_failed, :rate_limited}
      ])

    assert output ==
             "┊ hmm\nthe answer\n  → echo\n  ✓ echo\n✗ the turn failed: :rate_limited\n"
  end

  test "ignores events it does not render" do
    output = render(Fleet.id(), [{:chunk, "c"}, {:meta, %{}}, {:tool_call, %{}}])

    assert output == ""
  end

  test "only receives its own agent's events" do
    mine = Fleet.id()
    theirs = Fleet.id()

    output =
      capture_io(fn ->
        {:ok, console} = Console.start_link(agent_id: mine)
        Events.emit(theirs, {:result, "not mine\n"})
        Events.emit(mine, {:result, "mine\n"})
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
          {:tool_denied, "call_1", "shell", String.duplicate("x", 40), %{by: :default, hooks: []}}
        )

        :sys.get_state(console)
      end)

    assert output == "  ✗ shell was refus…\n"
  end
end
