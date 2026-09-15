defmodule Tars.TUITest do
  use ExUnit.Case, async: false

  alias Tars.Event
  alias Tars.Event.Source
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

    {:ok, tui: tui, agent_id: agent_id, turn: Source.root(agent_id, name: "turn")}
  end

  defp sync(tui), do: :sys.get_state(tui)

  defp emit(source, payload), do: Event.emit(source, payload)

  defp turn(context, payloads) do
    Enum.each(payloads, &emit(context.turn, &1))
    sync(context.tui)
  end

  test "greets with a banner on start" do
    assert_receive {:screen, {:write, _banner}}
  end

  test "a starting turn starts the status line", context do
    turn(context, [{:turn_started, ["hello"]}])

    assert_receive {:screen, {:status, _label}}
  end

  describe "the answer" do
    test "reaches the transcript a line at a time as it streams", context do
      turn(context, [
        {:turn_started, ["hi"]},
        {:result, "the first "},
        {:result, "line\nthe se"}
      ])

      assert writes() |> Enum.join() =~ "the first line\n"
      refute writes() |> Enum.join() =~ "the se"
    end

    test "markdown is rendered, not printed raw", context do
      turn(context, [
        {:turn_started, ["hi"]},
        {:result, "## Findings\n- a **bold** point\n"}
      ])

      transcript = writes() |> Enum.join()

      assert transcript =~ "Findings"
      assert transcript =~ "• a bold point"
      refute transcript =~ "##"
      refute transcript =~ "**"
    end

    test "the last line lands even without its newline", context do
      turn(context, [
        {:turn_started, ["hi"]},
        {:result, "no trailing newline"},
        {:turn_finished, []}
      ])

      assert writes() |> Enum.join() =~ "no trailing newline"
    end

    test "the status line is erased before anything is written", context do
      drain()
      turn(context, [{:turn_started, ["hi"]}, {:result, "hello\n"}])

      events = screen_events()
      write_at = Enum.find_index(events, &match?({:write, _}, &1))
      clear_at = Enum.find_index(events, &(&1 == :clear_status))

      assert clear_at < write_at
    end
  end

  describe "reasoning" do
    test "stays off the transcript and shows on the status line", context do
      turn(context, [{:turn_started, ["hi"]}, {:thinking, "pondering"}])

      assert labels() |> Enum.any?(&(&1 =~ "pondering"))
      refute writes() |> Enum.join() =~ "pondering"
    end

    test "is committed to the transcript in verbose mode", %{agent_id: agent_id} do
      RecordingScreen.attach()
      turn = Source.root(agent_id, name: "turn")

      tui =
        start_supervised!(
          {TUI,
           agent: self(), agent_id: agent_id, screen: RecordingScreen, reader: nil, verbose: true},
          id: :verbose_tui
        )

      emit(turn, {:turn_started, ["hi"]})
      emit(turn, {:thinking, "pondering aloud\n"})
      sync(tui)

      assert writes() |> Enum.join() =~ "pondering aloud"
    end
  end

  describe "the span tree" do
    setup %{turn: turn} do
      {:ok, tool: Source.child(turn, name: "deep_research")}
    end

    test "a span prints a line when it opens and when it closes", context do
      %{tool: tool} = context
      turn(context, [{:turn_started, ["hi"]}])

      emit(tool, {:span_started, "deep_research"})
      emit(tool, {:span_finished, :ok, 1_200})
      sync(context.tui)

      transcript = writes() |> Enum.join()

      assert transcript =~ "· deep_research"
      assert transcript =~ "✓ deep_research"
      assert transcript =~ "1.2s"
    end

    test "nested work is indented by its depth", context do
      %{tool: tool} = context
      branch = Source.child(tool, name: "pricing")

      turn(context, [{:turn_started, ["hi"]}])

      emit(tool, {:span_started, "deep_research"})
      emit(branch, {:span_started, "pricing"})
      sync(context.tui)

      lines = writes() |> Enum.join() |> String.split("\n")

      assert Enum.any?(lines, &(&1 == "  · deep_research"))
      assert Enum.any?(lines, &(&1 == "    · pricing"))
    end

    test "a failed span says why", context do
      %{tool: tool} = context
      turn(context, [{:turn_started, ["hi"]}])

      emit(tool, {:span_started, "pricing"})
      emit(tool, {:span_finished, {:error, :timeout}, 20_000})
      sync(context.tui)

      assert writes() |> Enum.join() =~ "✗ pricing · :timeout"
    end

    test "nested spans drive the status line, which the old root filter dropped", context do
      %{tool: tool} = context
      turn(context, [{:turn_started, ["hi"]}])

      emit(tool, {:span_started, "deep_research"})
      emit(tool, {:tool_started, "call_1", "deep_research"})
      sync(context.tui)

      assert labels() |> Enum.any?(&(&1 =~ "deep_research"))
    end

    test "the tree resets between turns", context do
      %{tool: tool} = context

      turn(context, [{:turn_started, ["one"]}])
      emit(tool, {:span_started, "deep_research"})
      emit(tool, {:span_finished, :ok, 10})
      turn(context, [{:turn_finished, []}])
      drain()

      turn(context, [{:turn_started, ["two"]}, {:thinking, "fresh"}])

      refute labels() |> Enum.any?(&(&1 =~ "deep_research"))
    end
  end

  describe "input arriving mid-turn" do
    test "is echoed so it is visibly accepted", context do
      turn(context, [{:turn_started, ["hi"]}])
      drain()

      send(context.tui, {:input, "focus on pricing"})
      sync(context.tui)

      transcript = writes() |> Enum.join()

      assert transcript =~ "focus on pricing"
      assert transcript =~ "»"
    end

    test "is forwarded to the agent", context do
      turn(context, [{:turn_started, ["hi"]}])

      send(context.tui, {:input, "focus on pricing"})
      sync(context.tui)

      assert_receive {:"$gen_cast", {:ask, "focus on pricing"}}
    end

    test "is not echoed when idle, because the terminal already did", context do
      drain()

      send(context.tui, {:input, "a fresh question"})
      sync(context.tui)

      refute writes() |> Enum.join() =~ "»"
    end
  end

  describe "/stop" do
    test "interrupts the agent rather than sending it a message", %{tui: tui} do
      send(tui, :stop)
      sync(tui)

      assert_receive {:"$gen_cast", :interrupt}
      refute_received {:"$gen_cast", {:ask, _text}}
    end

    test "an interrupted turn reports what it stopped and reprompts", context do
      turn(context, [{:turn_started, ["hi"]}, {:result, "half a th"}])
      drain()

      turn(context, [
        {:turn_interrupted, %{dropped: 2, kept: 1, resolution: :stopped, elapsed_ms: 4_200}}
      ])

      transcript = writes() |> Enum.join()

      assert transcript =~ "stopped"
      assert transcript =~ "4.2s"
      assert transcript =~ "2 queued messages dropped"
      assert transcript =~ "half a th"
    end

    test "an interrupt with nothing running says so", context do
      drain()

      turn(context, [
        {:turn_interrupted, %{dropped: 0, kept: 0, resolution: :idle, elapsed_ms: 0}}
      ])

      assert writes() |> Enum.join() =~ "nothing was running"
    end
  end

  describe "a finished turn" do
    test "stops the status line and reprompts", context do
      turn(context, [
        {:turn_started, ["hi"]},
        {:result, "the answer\n"},
        {:turn_finished, []}
      ])

      assert_receive {:screen, :clear_status}
      assert writes() |> Enum.join() =~ "the answer"
    end

    test "a failed turn shows the reason", context do
      turn(context, [{:turn_started, ["hi"]}, {:turn_failed, :rate_limited}])

      assert writes() |> Enum.join() =~ ":rate_limited"
    end

    test "counters reset between turns", context do
      turn(context, [{:turn_started, ["one"]}, {:result, "aaaa"}])
      assert labels() |> Enum.any?(&(&1 =~ "4 chars"))

      turn(context, [{:turn_finished, []}, {:turn_started, ["two"]}, {:result, "b"}])

      assert labels() |> Enum.any?(&(&1 =~ "1 chars"))
      refute labels() |> Enum.any?(&(&1 =~ "5 chars"))
    end
  end

  describe "verbose mode" do
    setup %{agent_id: agent_id} do
      RecordingScreen.attach()

      tui =
        start_supervised!(
          {TUI,
           agent: self(), agent_id: agent_id, screen: RecordingScreen, reader: nil, verbose: true},
          id: :verbose_tui
        )

      {:ok, tui: tui, turn: Source.root(agent_id, name: "turn")}
    end

    test "traces the model request, which chat mode leaves to the status line", context do
      turn(context, [
        {:turn_started, ["hi"]},
        {:model_started, {:anthropic, model: "x"}},
        {:model_finished, :ok, 1_200}
      ])

      transcript = writes() |> Enum.join()

      assert transcript =~ "model"
      assert transcript =~ "ok 1.2s"
    end

    test "still never prints a line per token", context do
      payloads =
        [{:turn_started, ["hi"]}] ++
          List.duplicate({:result, "tok"}, 200) ++ [{:turn_finished, []}]

      turn(context, payloads)

      lines = writes() |> Enum.join() |> String.split("\n", trim: true)

      # 200 token events, all on one unfinished line.
      assert Enum.count(lines) < 10
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

    test "/stop is a control command, not something the model reads" do
      assert TUI.command("/stop") == :stop
      assert TUI.command("  /stop  \n") == :stop

      # Emphatic prose is content and stays content.
      assert TUI.command("Stop!") == {:ask, "Stop!"}
      assert TUI.command("stop") == {:ask, "stop"}
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

      {:ok, tui: tui, agent_id: agent_id, reader: reader, turn: Source.root(agent_id)}
    end

    test "shows a prompt on start and again when a turn ends", context do
      assert writes() |> Enum.join() =~ "›"

      turn(context, [{:turn_started, ["hi"]}, {:turn_finished, []}])

      assert writes() |> Enum.join() =~ "›"
    end

    test "the reader is never told to wait, so input is accepted at any time", context do
      assert Process.info(context.reader, :messages) == {:messages, []}

      turn(context, [{:turn_started, ["hi"]}])

      assert Process.info(context.reader, :messages) == {:messages, []}
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

  defp screen_events(acc \\ []) do
    receive do
      {:screen, event} -> screen_events(acc ++ [event])
    after
      0 -> acc
    end
  end

  defp labels do
    collect(fn
      {:status, label} -> plain(label)
      _other -> nil
    end)
  end

  defp writes do
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
end
