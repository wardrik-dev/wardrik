defmodule Tars.ConsoleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Tars.Console
  alias Tars.Events

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
    output = render(make_ref(), [{:thinking, "hmm"}, {:result, "answer"}])

    assert output == "hmmanswer"
  end

  test "renders tool lifecycle" do
    output =
      render(make_ref(), [
        {:tool_started, "call_1", "echo"},
        {:tool_finished, "call_1", "echo", {:ok, "done"}},
        {:tool_finished, "call_2", "boom", {:error, :timeout}}
      ])

    assert output =~ "→ echo"
    assert output =~ "✓ echo"
    assert output =~ "✗ boom: :timeout"
  end

  test "ignores events it does not render" do
    output = render(make_ref(), [{:chunk, "c"}, {:meta, %{}}, {:tool_call, %{}}])

    assert output == ""
  end

  test "only receives its own agent's events" do
    mine = make_ref()
    theirs = make_ref()

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
