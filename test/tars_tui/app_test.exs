defmodule TarsTUI.AppTest do
  use ExUnit.Case, async: false

  alias Tars.Event
  alias Tars.Event.Source
  alias TarsTUI.App

  # The view is driven purely by events, so a fake agent id is enough — no
  # agent process is needed. `agent: self()` means `Agent.ask/2` and
  # `Agent.interrupt/1` land in this test's mailbox as casts.
  setup do
    agent_id = make_ref()

    session =
      Breeze.Test.start!(App,
        size: {70, 14},
        start_opts: [agent: self(), agent_id: agent_id, model: "test:model", sidebar: false],
        global_keybindings: App.keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    # Implicits such as the prompt only exist once a frame has been rendered.
    Breeze.Test.render_text!(session)

    {:ok, session: session, agent_id: agent_id, turn: Source.root(agent_id, name: "turn")}
  end

  defp screen(session), do: Breeze.Test.render_text!(session)

  defp type(session, text) do
    Enum.each(String.graphemes(text), &Breeze.Test.input(session, &1))
    session
  end

  defp submit(session, text) do
    session |> type(text) |> Breeze.Test.input("Enter")
    session
  end

  defp emit(source, payloads) when is_list(payloads),
    do: Enum.each(payloads, &Event.emit(source, &1))

  defp meta(usage), do: %ReqLLM.StreamChunk{type: :meta, metadata: %{usage: usage}}

  defp tool_call(name, arguments) do
    %ReqLLM.StreamChunk{type: :tool_call, name: name, arguments: arguments, metadata: %{}}
  end

  describe "the prompt" do
    test "shows what is typed", %{session: session} do
      type(session, "hello")

      assert screen(session) =~ "› hello"
    end

    test "sends a line to the agent and echoes it", %{session: session} do
      submit(session, "hello agent")

      assert_receive {:"$gen_cast", {:ask, "hello agent"}}
      assert screen(session) =~ "› hello agent"
    end

    test "is cleared after sending", %{session: session} do
      submit(session, "hello agent")

      assert screen(session) =~ "Ask anything"
    end

    test "a line sent during a turn is queued, not blocked", %{session: session, turn: turn} do
      emit(turn, [{:turn_started, ["first"]}])
      submit(session, "second thought")

      assert_receive {:"$gen_cast", {:ask, "second thought"}}
      text = screen(session)
      assert text =~ "» second thought"
      assert text =~ "queued"
      assert text =~ "1 prompt queued"
    end

    test "/stop interrupts and /quit stops", %{session: session} do
      submit(session, "/stop")
      assert_receive {:"$gen_cast", :interrupt}

      assert {:stop, _term} = submit(session, "/quit") |> then(fn _ -> {:stop, nil} end)
    end

    test "grows with a multi-line draft and shrinks back when sent", %{session: session} do
      prompt_rows = fn ->
        session |> screen() |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "│"))
      end

      type(session, "first")
      assert prompt_rows.() == 1

      Breeze.Test.input(session, %{"key" => "Enter", "shiftKey" => true})
      type(session, "second")
      assert prompt_rows.() == 2
      assert screen(session) =~ "second"

      Breeze.Test.input(session, "Enter")
      assert_receive {:"$gen_cast", {:ask, "first\nsecond"}}
      assert prompt_rows.() == 1
    end

    test "a blank line is ignored", %{session: session} do
      Breeze.Test.input(session, "Enter")

      refute_receive {:"$gen_cast", _}
    end
  end

  describe "keys" do
    test "Escape interrupts the turn", %{session: session} do
      Breeze.Test.input(session, "Escape")

      assert_receive {:"$gen_cast", :interrupt}
    end

    test "Ctrl-T toggles tracing", %{session: session, turn: turn} do
      refute screen(session) =~ "[trace]"

      Breeze.Test.input(session, %{"key" => "t", "ctrlKey" => true})
      emit(turn, [{:turn_started, ["hi"]}])
      assert screen(session) =~ "[trace]"

      Breeze.Test.input(session, %{"key" => "t", "ctrlKey" => true})
      emit(turn, [{:turn_finished, []}])
      refute screen(session) =~ "[trace]"
    end
  end

  describe "the transcript" do
    test "renders the answer as markdown, a line at a time", %{session: session, turn: turn} do
      emit(turn, [
        {:turn_started, ["hi"]},
        {:result, "## Findings\n- a **bold** point\nunfinished"}
      ])

      text = screen(session)
      assert text =~ "Findings"
      assert text =~ "• a bold point"
      refute text =~ "##"
      refute text =~ "**"
      refute text =~ "unfinished"
    end

    test "the answer is a bullet block set off by a blank line", %{session: session, turn: turn} do
      emit(turn, [{:turn_started, ["hi"]}, {:result, "first line\nsecond line\n"}])

      assert screen(session) =~ ~r/\n\s*\n⏺ first line\s*\n  second line/
    end

    test "the last line lands when the turn ends", %{session: session, turn: turn} do
      emit(turn, [{:turn_started, ["hi"]}, {:result, "no newline"}, {:turn_finished, []}])

      assert screen(session) =~ "no newline"
    end

    test "text streamed by delegated work stays out of the prose", %{session: session, turn: turn} do
      branch = Source.child(turn, name: "researcher")
      emit(turn, [{:turn_started, ["hi"]}])
      emit(branch, [{:span_started, "researcher"}, {:result, "private findings\n"}])

      text = screen(session)
      assert text =~ "· researcher"
      refute text =~ "private findings"
    end

    test "spans draw as a tree with outcomes", %{session: session, turn: turn} do
      tool = Source.child(turn, name: "deep_research")
      angle = Source.child(tool, name: "pricing")

      emit(turn, [{:turn_started, ["hi"]}])
      emit(tool, [{:span_started, "deep_research"}])
      emit(angle, [{:span_started, "pricing"}, {:span_finished, {:error, :timeout}, 5_000}])
      emit(tool, [{:span_finished, :ok, 6_000}])

      text = screen(session)
      assert text =~ "  · deep_research"
      assert text =~ "    · pricing"
      assert text =~ "    ✗ pricing · :timeout · 5.0s"
      assert text =~ "        ↳ :timeout"
      assert text =~ "  ✓ deep_research · 6.0s"
    end

    test "a failed span's reason is written in full under it", %{session: session, turn: turn} do
      tool = Source.child(turn, name: "deep_research")

      reason =
        {:no_findings, Enum.map(1..5, &%{"angle" => "angle number #{&1}", "reason" => ":killed"})}

      emit(turn, [{:turn_started, ["hi"]}])
      emit(tool, [{:span_started, "deep_research"}, {:span_finished, {:error, reason}, 1_000}])

      text = screen(session)
      assert text =~ "✗ deep_research · {:no_findings"
      assert text =~ ~r/↳ \{:no_findings, \[%\{"angle" => "angle number 1"(.|\n)*"angle number 5"/
    end

    test "a tool call shows its arguments, clipped to one row", %{session: session, turn: turn} do
      long = String.duplicate("lemonade ", 20)

      emit(turn, [
        {:turn_started, ["hi"]},
        {:tool_call, tool_call("web_search", %{"query" => "lemonade"})}
      ])

      emit(turn, [{:tool_call, tool_call("web_search", %{"query" => long})}])

      text = screen(session)
      assert text =~ ~s(⇢ web_search {"query":"lemonade"})
      assert text =~ ~r/⇢ web_search \{"query":"lemonade lemonade .*…/
      refute text =~ ~r/^lemonade/m
    end

    test "a partial tool call, without arguments, draws nothing", %{session: session, turn: turn} do
      emit(turn, [{:turn_started, ["hi"]}, {:tool_call, tool_call("web_search", %{})}])

      refute screen(session) =~ "⇢"
    end

    test "stays pinned to the newest line as it grows", %{session: session, turn: turn} do
      emit(turn, [{:turn_started, ["hi"]}])
      emit(turn, for(i <- 1..40, do: {:result, "line #{i}\n"}))

      text = screen(session)
      assert text =~ "line 40"
      refute text =~ "line 1\n"
    end

    test "the wheel scrolls a few rows at a time and unpins from the bottom", %{
      session: session,
      turn: turn
    } do
      emit(turn, [{:turn_started, ["hi"]}])
      emit(turn, for(i <- 1..40, do: {:result, "line #{i}\n"}))
      assert screen(session) =~ "line 40"

      Breeze.Test.wheel(session, "log", :up)
      text = screen(session)
      assert text =~ "line 37"
      refute text =~ "line 40"

      emit(turn, [{:result, "line 41\n"}])
      refute screen(session) =~ "line 41"

      Enum.each(1..3, fn _ -> Breeze.Test.wheel(session, "log", :down) end)
      assert screen(session) =~ "line 41"
    end

    test "rows re-wrap when the terminal is resized", %{session: session, turn: turn} do
      emit(turn, [{:turn_started, ["hi"]}, {:result, String.duplicate("word ", 20) <> "\n"}])
      assert screen(session) =~ ~r/^⏺ word word.*\n  (word )+/m

      wide = Breeze.Test.resize(session, {130, 14})
      # The first frame at the new width asks for the re-wrap; the next shows it.
      screen(wide)
      assert screen(wide) =~ ~r/^⏺ word (word ){18}word/m
    end

    test "an interrupt and a failure are both reported", %{session: session, turn: turn} do
      emit(turn, [
        {:turn_started, ["hi"]},
        {:turn_interrupted, %{resolution: :killed, elapsed_ms: 1_500, dropped: 2, kept: 0}}
      ])

      text = screen(session)
      assert text =~ "■ stopped · 1.5s · killed · 2 queued messages dropped"

      emit(turn, [{:turn_started, ["again"]}, {:turn_failed, :boom}])
      assert screen(session) =~ "✗ :boom"
    end
  end

  describe "the activity row" do
    test "is idle between turns", %{session: session} do
      assert screen(session) =~ "idle"
    end

    test "names the innermost work and the newest reasoning", %{
      session: session,
      turn: turn
    } do
      tool = Source.child(turn, name: "web_search")

      emit(turn, [{:turn_started, ["hi"]}, {:thinking, "I should look this up carefully"}])
      assert screen(session) =~ "turn · I should look this up carefully"

      emit(tool, [{:span_started, "web_search"}])
      text = screen(session)
      assert text =~ "web_search"
      refute text =~ "idle"
      refute text =~ "look this up"

      emit(tool, [{:span_finished, :ok, 10}])
      emit(turn, [{:model_started, "m"}, {:thinking, " and then decide"}])

      assert screen(session) =~ "turn · I should look this up carefully and then decide"
    end

    test "a chunk ending in a space still separates words", %{session: session, turn: turn} do
      emit(turn, [{:turn_started, ["hi"]}, {:thinking, "I should "}, {:thinking, "rank these"}])

      assert screen(session) =~ "turn · I should rank these"
    end

    test "long reasoning shows its newest words, cut at a word and marked", %{
      session: session,
      turn: turn
    } do
      words = Enum.map_join(1..30, " ", &"word#{&1}")
      emit(turn, [{:turn_started, ["hi"]}, {:thinking, words}])

      [row] = session |> screen() |> String.split("\n") |> Enum.filter(&(&1 =~ "turn ·"))

      assert row =~ ~r/turn · …word\d+ /
      assert row =~ "word30"
    end

    test "reasoning stays off the transcript unless tracing is on", %{
      session: session,
      turn: turn
    } do
      emit(turn, [{:turn_started, ["hi"]}, {:thinking, "secret plan\n"}])
      refute screen(session) =~ "┊ secret plan"

      Breeze.Test.input(session, %{"key" => "t", "ctrlKey" => true})
      emit(turn, [{:thinking, "open plan\n"}])
      assert screen(session) =~ "┊ open plan"
    end
  end

  describe "the meta row" do
    test "adds up tokens and cost across concurrent requests", %{session: session, turn: turn} do
      branch = Source.child(turn, name: "researcher")

      emit(turn, [{:turn_started, ["hi"]}, {:model_started, "m"}])
      emit(branch, [{:model_started, "m"}])
      emit(turn, [{:meta, meta(%{input_tokens: 1_000, output_tokens: 100, total_cost: 0.01})}])
      emit(branch, [{:meta, meta(%{input_tokens: 500, output_tokens: 50, total_cost: 0.005})}])

      refute screen(session) =~ "req"

      emit(turn, [{:model_finished, :ok, 10}])
      emit(branch, [{:model_finished, :ok, 10}])

      text = screen(session)
      assert text =~ "↑ 1.5k in"
      assert text =~ "↓ 150 out"
      assert text =~ "$0.02"
      assert text =~ "2 req"
    end
  end
end
