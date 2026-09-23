defmodule TarsConsoleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Tars.Test.Events
  alias Tars.Test.Fleet
  alias TarsConsole, as: Console

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

  test "renders result and thinking text verbatim" do
    output = render(Fleet.key(), [{:thinking, "hmm"}, {:result, "answer"}])

    assert output == "hmmanswer"
  end

  test "renders tool lifecycle" do
    output =
      render(Fleet.key(), [
        {:tool_started, "call_1", "echo"},
        {:tool_finished, "call_1", "echo", {:ok, "done"}},
        {:tool_finished, "call_2", "boom", {:error, :timeout}}
      ])

    assert output =~ "→ echo"
    assert output =~ "✓ echo"
    assert output =~ "✗ boom: :timeout"
  end

  test "renders turn completion and failure" do
    output =
      render(Fleet.key(), [
        {:result, "answer"},
        {:turn_finished, []},
        {:turn_failed, :rate_limited}
      ])

    assert output =~ "answer"
    assert output =~ "turn failed: :rate_limited"
  end

  test "ignores events it does not render" do
    output = render(Fleet.key(), [{:chunk, "c"}, {:meta, %{}}, {:tool_call, %{}}])

    assert output == ""
  end

  test "only receives its own agent's events" do
    mine = Fleet.key()
    theirs = Fleet.key()

    output =
      capture_io(fn ->
        {:ok, console} = Console.start_link(agent_id: mine)
        Events.emit(theirs, {:result, "not mine"})
        Events.emit(mine, {:result, "mine"})
        :sys.get_state(console)
      end)

    assert output == "mine"
  end
end
