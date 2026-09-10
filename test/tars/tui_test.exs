defmodule Tars.TUITest do
  use ExUnit.Case, async: false

  alias Tars.Test.Events
  alias Tars.Test.RecordingScreen
  alias Tars.TUI

  # The TUI is driven purely by events, so a fake agent id is enough — no agent
  # process is needed to exercise any of this.
  setup do
    RecordingScreen.attach()
    agent_id = make_ref()

    tui =
      start_supervised!(
        {TUI, agent: self(), agent_id: agent_id, screen: RecordingScreen, reader: nil}
      )

    {:ok, tui: tui, agent_id: agent_id}
  end

  defp sync(tui), do: :sys.get_state(tui)

  test "greets with a banner on start" do
    assert_receive {:screen, {:write, _banner}}
  end

  test "a starting turn starts the status line", %{tui: tui, agent_id: agent_id} do
    Events.emit(agent_id, {:turn_started, ["hello"]})
    sync(tui)

    assert_receive {:screen, {:status, _label}}
  end

  test "streamed text is written straight through, not redrawn", %{tui: tui, agent_id: agent_id} do
    Events.emit(agent_id, {:turn_started, ["hi"]})
    Events.emit(agent_id, {:result, "Hel"})
    Events.emit(agent_id, {:result, "lo"})
    sync(tui)

    assert collect_writes() |> Enum.join() =~ "Hello"
  end

  test "thinking goes to the status line, never the transcript", %{
    tui: tui,
    agent_id: agent_id
  } do
    Events.emit(agent_id, {:turn_started, ["hi"]})
    Events.emit(agent_id, {:thinking, "pondering"})
    sync(tui)

    assert collect_labels() |> Enum.any?(&(&1 =~ "pondering"))
    refute collect_writes() |> Enum.join() =~ "pondering"
  end

  test "tool activity drives the status line", %{tui: tui, agent_id: agent_id} do
    Events.emit(agent_id, {:turn_started, ["hi"]})
    Events.emit(agent_id, {:tool_started, "call_1", "echo"})
    Events.emit(agent_id, {:tool_finished, "call_1", "echo", {:ok, "done"}})
    Events.emit(agent_id, {:tool_started, "call_2", "boom"})
    Events.emit(agent_id, {:tool_finished, "call_2", "boom", {:error, :nope}})
    sync(tui)

    labels = collect_labels()

    assert Enum.any?(labels, &(&1 =~ "• echo"))
    assert Enum.any?(labels, &(&1 =~ "✓ echo"))
    assert Enum.any?(labels, &(&1 =~ "✗ boom"))
  end

  test "a finished turn stops the status line and reprompts", %{tui: tui, agent_id: agent_id} do
    Events.emit(agent_id, {:turn_started, ["hi"]})
    Events.emit(agent_id, {:result, "the answer"})
    Events.emit(agent_id, {:turn_finished, []})
    sync(tui)

    assert_receive {:screen, :clear_status}
    assert collect_writes() |> Enum.join() =~ "the answer"
  end

  test "a failed turn stops the status line with an error and shows the reason", %{
    tui: tui,
    agent_id: agent_id
  } do
    Events.emit(agent_id, {:turn_started, ["hi"]})
    Events.emit(agent_id, {:turn_failed, :rate_limited})
    sync(tui)

    assert_receive {:screen, :clear_status}
    assert collect_writes() |> Enum.join() =~ ":rate_limited"
  end

  test "state resets between turns", %{tui: tui, agent_id: agent_id} do
    Events.emit(agent_id, {:turn_started, ["one"]})
    Events.emit(agent_id, {:thinking, "first thoughts"})
    Events.emit(agent_id, {:tool_started, "c1", "echo"})
    Events.emit(agent_id, {:turn_finished, []})
    Events.emit(agent_id, {:turn_started, ["two"]})
    Events.emit(agent_id, {:thinking, "second thoughts"})
    sync(tui)

    latest = collect_labels() |> List.last()

    assert latest =~ "second thoughts"
    refute latest =~ "echo"
  end

  test "events from work a turn spawned are left to a nested view", %{
    tui: tui,
    agent_id: agent_id
  } do
    Events.emit(agent_id, {:turn_started, ["hi"]})
    drain()

    Events.emit_nested(agent_id, {:result, "from a subagent"})
    Events.emit_nested(agent_id, {:tool_started, "c1", "nested_tool"})
    sync(tui)

    refute collect_writes() |> Enum.join() =~ "from a subagent"
    refute collect_labels() |> Enum.any?(&(&1 =~ "nested_tool"))
  end

  test "chat mode ignores the low-level events", %{tui: tui, agent_id: agent_id} do
    # The banner and prompt are written at start-up; ignore them.
    drain()

    Events.emit(agent_id, {:chunk, "raw"})
    Events.emit(agent_id, {:meta, %{}})
    Events.emit(agent_id, {:tool_call, %{}})
    sync(tui)

    refute_received {:screen, {:write, _}}
    refute_received {:screen, {:status, _}}
    assert Process.alive?(tui)
  end

  describe "verbose mode" do
    setup do
      RecordingScreen.attach()
      agent_id = make_ref()

      tui =
        start_supervised!(
          {TUI,
           agent: self(), agent_id: agent_id, screen: RecordingScreen, reader: nil, verbose: true},
          id: :verbose_tui
        )

      {:ok, tui: tui, agent_id: agent_id}
    end

    test "traces structural events, one line each", %{tui: tui, agent_id: agent_id} do
      Events.emit(agent_id, {:turn_started, ["hi"]})
      Events.emit(agent_id, {:meta, %{}})
      Events.emit(agent_id, {:tool_started, "c1", "echo"})
      Events.emit(agent_id, {:tool_finished, "c1", "echo", {:ok, :done}})
      Events.emit(agent_id, {:turn_finished, []})
      sync(tui)

      trace = collect_writes() |> Enum.join()

      for kind <- ~w(turn_started meta tool_started tool_finished turn_finished) do
        assert trace =~ kind
      end
    end

    test "never prints a line per token — they are counted instead", %{
      tui: tui,
      agent_id: agent_id
    } do
      Events.emit(agent_id, {:turn_started, ["hi"]})

      for _ <- 1..200 do
        Events.emit(agent_id, {:chunk, %{type: :content}})
        Events.emit(agent_id, {:result, "tok"})
      end

      Events.emit(agent_id, {:thinking, "pondering"})
      Events.emit(agent_id, {:turn_finished, []})
      sync(tui)

      trace = collect_writes() |> Enum.join()
      lines = String.split(trace, "\n", trim: true)

      # 400 token events; a naive trace would be 400 lines.
      assert Enum.count(lines) < 10
      refute trace =~ "tok"

      # One summary line stands in for the whole stream.
      assert trace =~ "stream"
      assert trace =~ "200 chunks"
      assert trace =~ "600 chars"
    end

    test "counters reset between turns", %{tui: tui, agent_id: agent_id} do
      Events.emit(agent_id, {:turn_started, ["one"]})
      Events.emit(agent_id, {:chunk, %{}})
      Events.emit(agent_id, {:turn_finished, []})
      Events.emit(agent_id, {:turn_started, ["two"]})
      Events.emit(agent_id, {:chunk, %{}})
      Events.emit(agent_id, {:chunk, %{}})
      Events.emit(agent_id, {:turn_finished, []})
      sync(tui)

      summaries =
        collect_writes()
        |> Enum.filter(&(&1 =~ "stream"))
        |> Enum.map(&String.trim/1)

      assert [first, second] = summaries
      assert first =~ "1 chunks"
      assert second =~ "2 chunks"
    end

    test "still drives the status line", %{tui: tui, agent_id: agent_id} do
      Events.emit(agent_id, {:turn_started, ["hi"]})
      sync(tui)

      assert_receive {:screen, {:status, _label}}
    end
  end

  describe "command/1" do
    test "blank lines are ignored" do
      assert TUI.command("") == :blank
      assert TUI.command("   \n") == :blank
    end

    test "slash commands quit" do
      assert TUI.command("/quit") == :quit
      assert TUI.command("/exit\n") == :quit
    end

    test "anything else is a question, trimmed" do
      assert TUI.command("  what is up?  \n") == {:ask, "what is up?"}
    end
  end

  describe "with a reader" do
    setup do
      RecordingScreen.attach()
      agent_id = make_ref()
      reader = spawn(fn -> receive do: (:never -> :ok) end)

      tui =
        start_supervised!(
          {TUI, agent: self(), agent_id: agent_id, screen: RecordingScreen, reader: reader},
          id: :tui_with_reader
        )

      {:ok, tui: tui, agent_id: agent_id, reader: reader}
    end

    test "prompts on start and again when a turn ends", %{
      tui: tui,
      agent_id: agent_id,
      reader: reader
    } do
      assert reader_prompted?(reader)

      Events.emit(agent_id, {:turn_started, ["hi"]})
      Events.emit(agent_id, {:turn_finished, []})
      sync(tui)

      assert reader_prompted?(reader, 2)
    end

    test "typed input is forwarded to the agent", %{tui: tui} do
      send(tui, {:input, "hello there"})
      sync(tui)

      # `agent` is this process, so the cast lands here.
      assert_receive {:"$gen_cast", {:ask, "hello there"}}
    end

    test "the reader is stopped with the TUI", %{tui: tui, reader: reader} do
      ref = Process.monitor(reader)
      stop_supervised!(:tui_with_reader)
      refute Process.alive?(tui)

      assert_receive {:DOWN, ^ref, :process, ^reader, _reason}
    end
  end

  test "quits on request", %{tui: tui} do
    ref = Process.monitor(tui)
    send(tui, :quit)

    assert_receive {:DOWN, ^ref, :process, ^tui, :normal}
  end

  defp drain do
    receive do
      {:screen, _event} -> drain()
    after
      0 -> :ok
    end
  end

  defp collect_labels do
    collect(fn
      {:status, label} -> plain(label)
      _other -> nil
    end)
  end

  defp collect_writes do
    collect(fn
      {:write, data} -> plain(data)
      _other -> nil
    end)
  end

  defp collect(fun, acc \\ []) do
    receive do
      {:screen, event} ->
        case fun.(event) do
          nil -> collect(fun, acc)
          value -> collect(fun, acc ++ [value])
        end
    after
      0 -> acc
    end
  end

  defp plain(data), do: data |> Owl.Data.untag() |> to_string()

  # The reader is a bare process, so count :prompt messages in its mailbox.
  defp reader_prompted?(reader, count \\ 1) do
    {:messages, messages} = Process.info(reader, :messages)
    Enum.count(messages, &(&1 == :prompt)) >= count
  end
end
