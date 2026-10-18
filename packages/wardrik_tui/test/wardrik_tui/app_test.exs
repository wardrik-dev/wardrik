defmodule WardrikTUI.AppTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Wardrik.Agent.Message
  alias Wardrik.Event
  alias Wardrik.Event.Source
  alias Wardrik.Fleet
  alias WardrikTUI.App

  # The view is driven purely by events, so a fake agent is enough. It forwards
  # what it is asked, decided and interrupted to this test's mailbox as casts.
  # The fleet holds it under `agent_id`, taking a turn, so every operation on
  # the agent reaches it.
  setup do
    agent_id = Wardrik.Test.Fleet.id()
    {:ok, agent} = Wardrik.Test.FakeAgent.start_link(self())
    test = self()

    Mimic.set_mimic_global()

    stub(Fleet, :whereis, fn
      ^agent_id, _opts -> agent
      id, opts -> call_original(Fleet, :whereis, [id, opts])
    end)

    stub(Fleet, :lookup, fn
      ^agent_id ->
        %Fleet.Member{
          id: agent_id,
          pid: agent,
          node: node(),
          status: :running,
          pending: 0,
          waiting_on: []
        }

      id ->
        call_original(Fleet, :lookup, [id])
    end)

    session =
      Breeze.Test.start!(App,
        size: {70, 14},
        start_opts: [
          agent: agent,
          agent_id: agent_id,
          host: Wardrik.Host.new(store: Wardrik.Test.store()),
          model: "test:model",
          sidebar: false,
          clipboard: fn text ->
            send(test, {:copied, text})
            :ok
          end
        ],
        global_keybindings: App.keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    # Implicits such as the prompt only exist once a frame has been rendered.
    Breeze.Test.render_text!(session)

    {:ok,
     session: session, agent: agent, agent_id: agent_id, turn: Source.root(agent_id, name: "turn")}
  end

  defp screen(session), do: Breeze.Test.render_text!(session)

  defp type(session, text) do
    Enum.each(String.graphemes(text), &Breeze.Test.input(session, &1))
    session
  end

  # Takes `text` back out of the prompt, one Backspace per character.
  defp erase(session, text) do
    Enum.each(String.graphemes(text), fn _grapheme -> Breeze.Test.input(session, "\x7f") end)
    session
  end

  # A frame before the keys, as there always is at a terminal: the prompt is
  # reset when a line is sent and only exists again once a frame has drawn it.
  defp submit(session, text) do
    screen(session)
    session |> type(text) |> Breeze.Test.input("Enter")
    session
  end

  defp emit(source, payloads) when is_list(payloads),
    do: Enum.each(payloads, &Event.emit(source, &1))

  defp meta(usage), do: %ReqLLM.StreamChunk{type: :meta, metadata: %{usage: usage}}

  defp call(name), do: %{id: "call_#{name}", name: name, arguments: %{}}

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

      assert_receive {:"$gen_cast", {:ask, %Wardrik.Agent.Message{text: "hello agent"}}}
      assert screen(session) =~ "› hello agent"
    end

    test "is cleared after sending", %{session: session} do
      submit(session, "hello agent")

      assert screen(session) =~ "Ask anything"
    end

    test "a line sent during a turn steers it, and is not blocked", %{
      session: session,
      turn: turn
    } do
      emit(turn, [%Event.TurnStarted{messages: [Message.new("first")]}])
      assert screen(session) =~ "Enter steers the turn at its next boundary"
      submit(session, "second thought")

      assert_receive {:"$gen_cast", {:ask, %Wardrik.Agent.Message{text: "second thought"}}}
      text = screen(session)
      assert text =~ "» second thought  · steers the turn at its next boundary"
      assert text =~ "1 message steering the turn"
    end

    test "a line sent while parked queues behind the decision", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("first")]},
        %Event.TurnParked{calls: [{call("deploy"), "Ship it?"}]}
      ])

      assert screen(session) =~ "Enter queues behind the parked turn"

      submit(session, "also this")

      assert_receive {:"$gen_cast", {:ask, %Wardrik.Agent.Message{text: "also this"}}}
      text = screen(session)
      assert text =~ "» also this  · queued behind the parked turn"
      assert text =~ "1 message queued behind the parked turn"
    end

    test "a mistyped command is reported with the nearest ones, and never sent", ctx do
      %{session: session} = ctx
      submit(session, "/spwan helper")

      refute_receive {:"$gen_cast", {:ask, _text}}
      text = screen(session)
      assert text =~ "/spwan is not a command"
      assert text =~ "did you mean /spawn"
      assert text =~ "start with // to send the line as typed"
    end

    test "a line that went wrong stays in the prompt for correction", %{session: session} do
      submit(session, "/spwan helper")
      assert screen(session) =~ "│ › /spwan helper"

      erase(session, "/spwan helper")
      submit(session, "/connect one two")
      assert screen(session) =~ "│ › /connect one two"
    end

    test "a line for an agent that has stopped says nothing was sent", ctx do
      %{session: session, agent: agent} = ctx
      GenServer.stop(agent)
      submit(session, "hello?")

      assert screen(session) =~ "is not running · nothing was sent"
    end

    test "a line for an agent the fleet no longer holds says nothing was sent", ctx do
      %{session: session} = ctx
      stub(Fleet, :whereis, fn _id, _opts -> nil end)
      submit(session, "hello?")

      refute_receive {:"$gen_cast", {:ask, _message}}
      assert screen(session) =~ "is not running · nothing was sent"
    end

    test "two slashes send text that begins with one", %{session: session} do
      submit(session, "//spawn is a word here")

      assert_receive {:"$gen_cast", {:ask, %Wardrik.Agent.Message{text: "/spawn is a word here"}}}
      assert screen(session) =~ "› /spawn is a word here"
    end

    test "a command given the wrong thing shows its usage", %{session: session} do
      submit(session, "/connect one two")

      refute_receive {:"$gen_cast", {:ask, _text}}
      assert screen(session) =~ "usage: /connect [NAME]"
    end

    test "/stop interrupts a turn, says when there is none, and /quit stops", %{
      session: session,
      turn: turn,
      agent_id: agent_id
    } do
      submit(session, "/stop")
      refute_receive {:"$gen_cast", :interrupt}
      assert screen(session) =~ "#{agent_id} is taking no turn"

      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
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
      assert_receive {:"$gen_cast", {:ask, %Wardrik.Agent.Message{text: "first\nsecond"}}}
      assert prompt_rows.() == 1
    end

    test "a blank line is ignored", %{session: session} do
      Breeze.Test.input(session, "Enter")

      refute_receive {:"$gen_cast", _}
    end
  end

  describe "history" do
    defp up(session), do: Breeze.Test.input(session, "ArrowUp")
    defp down(session), do: Breeze.Test.input(session, "ArrowDown")

    test "Up recalls what was sent, and Down comes back to the unfinished draft", ctx do
      %{session: session} = ctx
      submit(session, "first question")
      submit(session, "second question")
      assert_receive {:"$gen_cast", {:ask, %Wardrik.Agent.Message{text: "first question"}}}
      assert_receive {:"$gen_cast", {:ask, %Wardrik.Agent.Message{text: "second question"}}}
      screen(session)
      type(session, "unfinished")

      up(session)
      assert screen(session) =~ "› second question"
      up(session)
      assert screen(session) =~ "› first question"
      up(session)
      assert screen(session) =~ "› first question"

      down(session)
      assert screen(session) =~ "› second question"
      down(session)
      assert screen(session) =~ "› unfinished"

      refute_receive {:"$gen_cast", {:ask, _recalled}}
    end

    test "a recalled line is sent with Enter, and edited before that", %{session: session} do
      submit(session, "hello")
      screen(session)

      up(session)
      type(session, " again")
      Breeze.Test.input(session, "Enter")

      assert_receive {:"$gen_cast", {:ask, %Wardrik.Agent.Message{text: "hello again"}}}
      assert screen(session) =~ "› hello again"
    end

    test "Up moves within a multi-line draft before reaching history", %{session: session} do
      submit(session, "sent before")
      screen(session)

      type(session, "one")
      Breeze.Test.input(session, %{"key" => "Enter", "shiftKey" => true})
      type(session, "two")

      up(session)
      text = screen(session)
      assert text =~ "│ › one"
      assert text =~ "│   two"

      up(session)
      text = screen(session)
      assert text =~ "│ › sent before"
      refute text =~ "│   two"

      down(session)
      text = screen(session)
      assert text =~ "│ › one"
      assert text =~ "│   two"
    end

    test "a draft starting with a slash walks the commands, kept apart", %{session: session} do
      submit(session, "a question")
      submit(session, "/help")
      Breeze.Test.input(session, "Escape")
      submit(session, "/spwan helper")
      screen(session)
      erase(session, "/spwan helper")

      up(session)
      assert screen(session) =~ "│ › a question"
      down(session)
      screen(session)

      type(session, "/")
      up(session)
      assert screen(session) =~ "│ › /spwan helper"
      up(session)
      assert screen(session) =~ "│ › /help"
      up(session)
      assert screen(session) =~ "│ › /help"
      down(session)
      down(session)
      assert screen(session) =~ ~r/│ › \/\s+│/
    end

    test "an answer to a parked call is not history", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.TurnParked{calls: [{call("deploy"), "Ship it?"}]}
      ])

      submit(session, "y")
      assert_receive {:"$gen_cast", {:resume, _decisions}}
      emit(turn, [%Event.TurnFinished{messages: []}])

      up(session)
      refute screen(session) =~ "› y"
    end
  end

  describe "the palette" do
    test "Ctrl-P opens it over the panes, and Esc closes it with the draft kept", ctx do
      %{session: session} = ctx
      session = Breeze.Test.resize(session, {70, 30})
      type(session, "kept draft")
      ctrl(session, "p")

      text = screen(session)
      assert text =~ "Commands · Ctrl-P"
      assert text =~ ~r/› Spawn an agent\s+\/spawn/
      assert text =~ "type to filter · Up/Down choose · Enter run · Esc close"
      assert Breeze.Test.focused(session) == "palette"

      Breeze.Test.input(session, "Escape")
      text = screen(session)
      refute text =~ "Commands · Ctrl-P"
      assert text =~ "│ › kept draft"
      assert Breeze.Test.focused(session) == "prompt"
    end

    test "letters narrow the commands, and Enter runs the one chosen", %{session: session} do
      ctrl(session, "p")
      screen(session)
      type(session, "every")

      text = screen(session)
      assert text =~ "› every▏"
      assert text =~ ~r/› Every key and command\s+\/help/
      refute text =~ "Spawn an agent"

      Breeze.Test.input(session, "Enter")
      text = screen(session)
      refute text =~ "Commands · Ctrl-P"
      assert text =~ "Help · every key and command"
      assert Breeze.Test.focused(session) == "palette"

      Breeze.Test.input(session, "Escape")
      assert Breeze.Test.focused(session) == "prompt"
    end

    test "Down and Up choose, and a command run lately comes first", %{session: session} do
      ctrl(session, "p")
      screen(session)
      Breeze.Test.input(session, "ArrowDown")
      assert screen(session) =~ "› Connect to an agent"
      Breeze.Test.input(session, "ArrowUp")
      assert screen(session) =~ "› Spawn an agent"

      type(session, "fleet")
      Breeze.Test.input(session, "Enter")
      assert screen(session) =~ "fleet · 0"
      assert Breeze.Test.focused(session) == "fleet"

      ctrl(session, "p")
      assert screen(session) =~ ~r/› Show the fleet panel\s+\/fleet\s+recent/
      Breeze.Test.input(session, "Escape")
    end

    test "offers what the moment allows: stopping a turn, deciding a parked call", ctx do
      %{session: session, turn: turn} = ctx
      ctrl(session, "p")
      text = screen(session)
      refute text =~ "Stop the turn"
      refute text =~ "Approve a parked call"
      Breeze.Test.input(session, "Escape")

      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      ctrl(session, "p")
      screen(session)
      type(session, "stop")
      assert screen(session) =~ ~r/› Stop the turn\s+\/stop\s+Esc/
      Breeze.Test.input(session, "Enter")
      assert_receive {:"$gen_cast", :interrupt}

      emit(turn, [%Event.TurnParked{calls: [{call("deploy"), "Ship it?"}]}])
      ctrl(session, "p")
      screen(session)
      type(session, "approve")
      Breeze.Test.input(session, "Enter")
      assert_receive {:"$gen_cast", {:resume, %{"call_deploy" => :approve}}}
      assert_receive {:decided_by, by}
      assert Wardrik.Principal.type(by) == :terminal
    end

    test "several parked calls are picked by number, and Backspace steps back", ctx do
      %{session: session, turn: turn} = ctx
      calls = [{call("deploy"), "Ship it?"}, {call("drop_table"), "Drop it?"}]

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.TurnParked{calls: calls}
      ])

      ctrl(session, "p")
      screen(session)
      type(session, "deny")
      Breeze.Test.input(session, "Enter")

      text = screen(session)
      assert text =~ "/deny · which call?"
      assert text =~ "› 1  deploy  Ship it?"
      assert text =~ "2  drop_table  Drop it?"

      Breeze.Test.input(session, "\x7f")
      assert screen(session) =~ "Commands · Ctrl-P"

      type(session, "deny")
      Breeze.Test.input(session, "Enter")
      screen(session)
      type(session, "drop")
      Breeze.Test.input(session, "Enter")

      assert_receive {:"$gen_cast", {:resume, %{"call_drop_table" => {:deny, _reason}}}}
      assert screen(session) =~ "▌ denied drop_table"
    end

    test "Ctrl-P from the transcript returns focus there when closed", %{session: session} do
      Breeze.Test.focus(session, "log")
      ctrl(session, "p")
      assert Breeze.Test.focused(session) == "palette"

      ctrl(session, "p")
      assert Breeze.Test.focused(session) == "log"
    end
  end

  describe "approvals" do
    test "one parked call takes a bare answer", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.TurnParked{calls: [{call("deploy"), "Ship it?"}]}
      ])

      text = screen(session)
      assert text =~ "APPROVAL NEEDED"
      assert text =~ "1  deploy"
      assert text =~ "y approve · n deny"

      submit(session, "y")

      assert_receive {:"$gen_cast", {:resume, %{"call_deploy" => :approve}}}
      assert screen(session) =~ "▌ approved deploy"
    end

    test "an answer for an agent the fleet no longer holds says nothing was sent", ctx do
      %{session: session, turn: turn} = ctx

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.TurnParked{calls: [{call("deploy"), "Ship it?"}]}
      ])

      stub(Fleet, :whereis, fn _id, _opts -> nil end)
      submit(session, "y")

      refute_receive {:"$gen_cast", {:resume, _decisions}}
      assert screen(session) =~ "is not running · nothing was sent"
    end

    test "several parked calls are decided one at a time, or all at once", ctx do
      %{session: session, turn: turn} = ctx
      calls = [{call("deploy"), "Ship it?"}, {call("drop_table"), "Drop it?"}]
      session = Breeze.Test.resize(session, {70, 30})

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.TurnParked{calls: calls}
      ])

      text = screen(session)
      assert text =~ "2 calls, each decided on its own"
      assert text =~ "Enter queues behind the parked turn · /approve N"
      assert text =~ "1  deploy"
      assert text =~ "2  drop_table"
      assert text =~ "/approve N approve one"

      submit(session, "y")
      refute_receive {:"$gen_cast", {:resume, _decisions}}
      assert screen(session) =~ "2 calls are waiting · say which"

      submit(session, "/approve 1")
      assert_receive {:"$gen_cast", {:resume, %{"call_deploy" => :approve} = one}}
      assert map_size(one) == 1
      assert screen(session) =~ "▌ approved deploy · 1 call still waiting"

      submit(session, "n 1 not that one")
      refute_receive {:"$gen_cast", {:resume, _decisions}}
      assert screen(session) =~ "no decision sent"
      emit(turn, [%Event.TurnParked{calls: [{call("drop_table"), "Drop it?"}]}])

      submit(session, "n 1 not that one")
      assert_receive {:"$gen_cast", {:resume, %{"call_drop_table" => {:deny, "not that one"}}}}
      assert screen(session) =~ "▌ denied drop_table · not that one"

      submit(session, "/approve 1")
      assert screen(session) =~ "nothing is waiting for a decision"
    end

    test "a resumed turn is running again, whoever answered it", %{session: session, turn: turn} do
      calls = [{call("deploy"), "Ship it?"}, {call("drop_table"), "Drop it?"}]

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.TurnParked{calls: calls}
      ])

      assert screen(session) =~ "waiting on deploy, drop"

      emit(turn, [%Event.TurnResumed{decisions: %{"call_deploy" => :approve}}])

      text = screen(session)
      refute text =~ "idle"
      refute text =~ "waiting on"
      assert text =~ "Enter steers the turn"

      # The other call is still parked, and the turn says so again.
      emit(turn, [%Event.TurnParked{calls: [{call("drop_table"), "Drop it?"}]}])
      assert screen(session) =~ "waiting on drop_table"
    end

    test "all answers every parked call", %{session: session, turn: turn} do
      calls = [{call("deploy"), "Ship it?"}, {call("drop_table"), "Drop it?"}]

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.TurnParked{calls: calls}
      ])

      submit(session, "/deny all not today")

      assert_receive {:"$gen_cast", {:resume, decisions}}

      assert decisions == %{
               "call_deploy" => {:deny, "not today"},
               "call_drop_table" => {:deny, "not today"}
             }

      assert screen(session) =~ "▌ denied deploy, drop_table · not today"
    end

    test "a number that picks nothing is said so", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.TurnParked{calls: [{call("deploy"), "Ship it?"}]}
      ])

      submit(session, "/approve 4")

      refute_receive {:"$gen_cast", {:resume, _decisions}}
      assert screen(session) =~ "nothing waiting is numbered 4"
    end
  end

  defp ctrl(session, letter),
    do: Breeze.Test.input(session, %{"key" => letter, "ctrlKey" => true})

  describe "keys" do
    test "Escape in the prompt stops a running turn, and nothing when idle", ctx do
      %{session: session, turn: turn} = ctx
      Breeze.Test.input(session, "Escape")
      refute_receive {:"$gen_cast", :interrupt}

      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      assert screen(session) =~ "Esc stops it"
      Breeze.Test.input(session, "Escape")
      assert_receive {:"$gen_cast", :interrupt}
    end

    test "Escape from another pane only returns to the prompt", %{session: session, turn: turn} do
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      Breeze.Test.focus(session, "log")
      Breeze.Test.input(session, "Escape")

      assert Breeze.Test.focused(session) == "prompt"
      refute_receive {:"$gen_cast", :interrupt}
    end

    test "Ctrl-X then s stops the turn from any pane", %{session: session, turn: turn} do
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      Breeze.Test.focus(session, "log")
      ctrl(session, "x")
      assert screen(session) =~ "s stop · Esc cancel"
      Breeze.Test.input(session, "s")

      assert_receive {:"$gen_cast", :interrupt}
      assert Breeze.Test.focused(session) == "log"
      refute screen(session) =~ "› s"
    end

    test "Ctrl-X then a direction moves focus, and the status row shows the moves", ctx do
      %{session: session} = ctx
      ctrl(session, "x")
      assert screen(session) =~ "Ctrl-X · k transcript · Esc cancel"

      Breeze.Test.input(session, "k")
      assert Breeze.Test.focused(session) == "log"
      assert screen(session) =~ "transcript · j/k scroll · Ctrl-U/D half page · / find"

      ctrl(session, "x")
      Breeze.Test.input(session, "j")
      assert Breeze.Test.focused(session) == "prompt"
      assert screen(session) =~ "Ctrl-X pane · Ctrl-F fleet"
    end

    test "Escape cancels a pending Ctrl-X, and letters then reach the prompt", ctx do
      %{session: session} = ctx
      ctrl(session, "x")
      Breeze.Test.input(session, "Escape")
      type(session, "hjkl")

      assert Breeze.Test.focused(session) == "prompt"
      assert screen(session) =~ "› hjkl"
    end

    test "i returns to the prompt from the transcript, and types there otherwise", ctx do
      %{session: session} = ctx
      Breeze.Test.focus(session, "log")
      Breeze.Test.input(session, "i")
      assert Breeze.Test.focused(session) == "prompt"

      type(session, "in")
      assert screen(session) =~ "› in"
    end

    test "Ctrl-D quits only from a prompt with nothing typed", %{session: session, turn: turn} do
      type(session, "unsent")
      ctrl(session, "d")
      assert screen(session) =~ "› unsent"

      # In the transcript the same key scrolls half a page.
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      emit(turn, for(i <- 1..40, do: %Event.Result{text: "line #{i}\n"}))
      Breeze.Test.focus(session, "log")
      ctrl(session, "u")
      text = screen(session)
      refute text =~ "line 40"
      ctrl(session, "d")
      assert screen(session) =~ "line 40"
    end

    test "Ctrl-F hides and shows the panel without moving focus", %{session: session} do
      # The session starts without a panel; Ctrl-F brings it in.
      ctrl(session, "f")
      assert screen(session) =~ "┌"
      assert Breeze.Test.focused(session) == "prompt"

      ctrl(session, "f")
      refute screen(session) =~ "┌"
    end

    test "Ctrl-T toggles tracing", %{session: session, turn: turn} do
      refute screen(session) =~ "[trace]"

      Breeze.Test.input(session, %{"key" => "t", "ctrlKey" => true})
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      assert screen(session) =~ "[trace]"

      Breeze.Test.input(session, %{"key" => "t", "ctrlKey" => true})
      emit(turn, [%Event.TurnFinished{messages: []}])
      refute screen(session) =~ "[trace]"
    end
  end

  describe "the transcript" do
    test "renders the answer as markdown, a line at a time", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Result{text: "## Findings\n- a **bold** point\nunfinished"}
      ])

      text = screen(session)
      assert text =~ "Findings"
      assert text =~ "• a bold point"
      refute text =~ "##"
      refute text =~ "**"
    end

    test "shows the line still arriving, and renders it once for good", ctx do
      %{session: session, turn: turn} = ctx

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Result{text: "a **bold**"}
      ])

      assert screen(session) =~ "⏺ a bold"

      emit(turn, [%Event.Result{text: " claim"}])
      assert screen(session) =~ "⏺ a bold claim"

      emit(turn, [%Event.Result{text: "\nand the next line"}])
      text = screen(session)
      assert text =~ "⏺ a bold claim"
      assert text =~ "  and the next line"
      refute text =~ "a bold claim\n  a bold claim"
    end

    test "the line still arriving leaves once its own line takes over", ctx do
      %{session: session, turn: turn} = ctx
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}, %Event.Result{text: "half"}])
      assert screen(session) =~ "⏺ half"

      emit(turn, [%Event.TurnFinished{messages: []}])
      text = screen(session)
      assert text =~ "⏺ half"
      refute text =~ "half\n  half"
    end

    test "the answer is a bullet block set off by a blank line", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Result{text: "first line\nsecond line\n"}
      ])

      assert screen(session) =~ ~r/\n\s*\n⏺ first line\s*\n  second line/
    end

    test "the last line lands when the turn ends", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Result{text: "no newline"},
        %Event.TurnFinished{messages: []}
      ])

      assert screen(session) =~ "no newline"
    end

    test "text streamed by delegated work stays out of the prose", %{session: session, turn: turn} do
      branch = Source.child(turn, name: "researcher")
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])

      emit(branch, [
        %Event.SpanStarted{name: "researcher"},
        %Event.Result{text: "private findings\n"}
      ])

      text = screen(session)
      assert text =~ "· researcher"
      refute text =~ "private findings"
    end

    test "spans draw as a tree with outcomes", %{session: session, turn: turn} do
      tool = Source.child(turn, name: "deep_research")
      angle = Source.child(tool, name: "pricing")

      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      emit(tool, [%Event.SpanStarted{name: "deep_research"}])

      emit(angle, [
        %Event.SpanStarted{name: "pricing"},
        %Event.SpanFinished{outcome: {:error, :timeout}, duration_ms: 5_000}
      ])

      emit(tool, [%Event.SpanFinished{outcome: :ok, duration_ms: 6_000}])

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

      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])

      emit(tool, [
        %Event.SpanStarted{name: "deep_research"},
        %Event.SpanFinished{outcome: {:error, reason}, duration_ms: 1_000}
      ])

      text = screen(session)
      assert text =~ "✗ deep_research · {:no_findings"
      assert text =~ ~r/↳ \{:no_findings, \[%\{"angle" => "angle number 1"(.|\n)*"angle number 5"/
    end

    test "a tool call shows its arguments, clipped to one row", %{session: session, turn: turn} do
      long = String.duplicate("lemonade ", 20)

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.ToolCall{call: tool_call("web_search", %{"query" => "lemonade"})}
      ])

      emit(turn, [%Event.ToolCall{call: tool_call("web_search", %{"query" => long})}])

      text = screen(session)
      assert text =~ ~s(⇢ web_search {"query":"lemonade"})
      assert text =~ ~r/⇢ web_search \{"query":"lemonade lemonade .*…/
      refute text =~ ~r/^lemonade/m
    end

    test "a partial tool call, without arguments, draws nothing", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.ToolCall{call: tool_call("web_search", %{})}
      ])

      refute screen(session) =~ "⇢"
    end

    test "stays pinned to the newest line as it grows", %{session: session, turn: turn} do
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      emit(turn, for(i <- 1..40, do: %Event.Result{text: "line #{i}\n"}))

      text = screen(session)
      assert text =~ "line 40"
      refute text =~ "line 1\n"
    end

    test "the wheel scrolls a few rows at a time and unpins from the bottom", %{
      session: session,
      turn: turn
    } do
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      emit(turn, for(i <- 1..40, do: %Event.Result{text: "line #{i}\n"}))
      assert screen(session) =~ "line 40"

      Breeze.Test.wheel(session, "log", :up)
      text = screen(session)
      assert text =~ "line 37"
      refute text =~ "line 40"

      emit(turn, [%Event.Result{text: "line 41\n"}])
      refute screen(session) =~ "line 41"

      Enum.each(1..3, fn _ -> Breeze.Test.wheel(session, "log", :down) end)
      assert screen(session) =~ "line 41"
    end

    test "rows re-wrap when the terminal is resized", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Result{text: String.duplicate("word ", 20) <> "\n"}
      ])

      assert screen(session) =~ ~r/^⏺ word word.*\n  (word )+/m

      wide = Breeze.Test.resize(session, {130, 14})
      # The first frame at the new width asks for the re-wrap; the next shows it.
      screen(wide)
      assert screen(wide) =~ ~r/^⏺ word (word ){18}word/m
    end

    test "an interrupt and a failure are both reported", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.TurnInterrupted{
          stats: %{resolution: :killed, elapsed_ms: 1_500, dropped: 2, kept: 0}
        }
      ])

      text = screen(session)
      assert text =~ "■ stopped · 1.5s · killed · 2 queued messages dropped"

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("again")]},
        %Event.TurnFailed{reason: :boom}
      ])

      assert screen(session) =~ "✗ :boom"
    end
  end

  describe "inspection" do
    # The status row: under the transcript's rule, above the prompt's box.
    defp status_row(session) do
      rows = session |> screen() |> String.split("\n")
      Enum.at(rows, length(rows) - 5)
    end

    defp lines(turn, range),
      do: emit(turn, for(i <- range, do: %Event.Result{text: "line #{i}\n"}))

    test "/ in the transcript searches it, Enter goes to the match, n and N step", ctx do
      %{session: session, turn: turn} = ctx
      session = Breeze.Test.resize(session, {70, 30})
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      lines(turn, 1..40)
      emit(turn, [%Event.TurnFinished{messages: []}])

      Breeze.Test.focus(session, "log")
      screen(session)
      Breeze.Test.input(session, "/")
      text = screen(session)
      assert text =~ "Search the transcript · Enter goes to the match"
      assert text =~ "type to search · Up/Down choose · Enter go there"

      type(session, "line 3")
      text = screen(session)
      assert text =~ ~r/›\s+\d+  line 3\s/
      assert text =~ ~r/\d+  line 30/

      Breeze.Test.input(session, "Enter")
      text = screen(session)
      assert Breeze.Test.focused(session) == "log"
      assert status_row(session) =~ "match 1 of 11 for line 3 · n next · N previous"
      [_header, first | _rest] = String.split(text, "\n")
      assert first =~ "line 3"

      Breeze.Test.input(session, "n")
      assert status_row(session) =~ "match 2 of 11"
      assert screen(session) =~ "line 30"

      Breeze.Test.input(session, "N")
      Breeze.Test.input(session, "N")
      assert status_row(session) =~ "match 11 of 11"
    end

    test "/find searches too, and n before any search says so", %{session: session, turn: turn} do
      session = Breeze.Test.resize(session, {70, 30})
      Breeze.Test.focus(session, "log")
      Breeze.Test.input(session, "n")
      assert status_row(session) =~ "nothing searched for yet · / searches"

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Result{text: "the lemonade stand\n"}
      ])

      Breeze.Test.focus(session, "prompt")
      submit(session, "/find lemonade")

      text = screen(session)
      assert text =~ "Search the transcript"
      assert text =~ "› lemonade▏"
      assert text =~ "the lemonade stand"

      Breeze.Test.input(session, "Enter")
      assert status_row(session) =~ "match 1 of 1 for lemonade"

      Breeze.Test.input(session, "/")
      type(session, "zzz")
      assert screen(session) =~ "nothing matches"
      Breeze.Test.input(session, "Escape")
      assert Breeze.Test.focused(session) == "log"
    end

    test "new output while scrolled up is announced until End follows it", ctx do
      %{session: session, turn: turn} = ctx
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      lines(turn, 1..30)
      Breeze.Test.focus(session, "log")
      screen(session)
      Breeze.Test.input(session, "Home")
      refute screen(session) =~ "new output below"

      lines(turn, 31..32)
      assert screen(session) =~ "↓ new output below · End to follow"

      Breeze.Test.input(session, "End")
      refute screen(session) =~ "new output below"
    end

    test "y copies the answer, and /copy code its last code block", %{
      session: session,
      turn: turn
    } do
      answer = "Run this:\n```sh\necho one\n```\nthen\n```sh\necho two\n```\n"

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Result{text: answer},
        %Event.TurnFinished{messages: []}
      ])

      Breeze.Test.focus(session, "log")
      screen(session)
      Breeze.Test.input(session, "y")
      assert_receive {:copied, ^answer}
      assert status_row(session) =~ "copied the answer · #{String.length(answer)} characters"

      Breeze.Test.focus(session, "prompt")
      submit(session, "/copy code")
      assert_receive {:copied, "echo two"}
      assert status_row(session) =~ "copied the last code block · 8 characters"
    end

    test "nothing to copy is said, not sent", %{session: session, turn: turn} do
      submit(session, "/copy")
      assert status_row(session) =~ "nothing to copy · no answer yet"

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Result{text: "prose only"},
        %Event.TurnFinished{messages: []}
      ])

      submit(session, "/copy code")
      assert status_row(session) =~ "nothing to copy · the answer has no code block"
      refute_receive {:copied, _text}
    end

    test "t lists the tool calls, and Enter shows one in full", %{session: session, turn: turn} do
      session = Breeze.Test.resize(session, {80, 24})

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.ToolCall{call: tool_call("web_search", %{"query" => "lemonade"})},
        %Event.ToolFinished{
          call_id: "call_1",
          name: "web_search",
          result: {:ok, %{"hits" => 3, "top" => "stand"}},
          served_by: nil,
          cost: nil
        },
        %Event.ToolCall{call: tool_call("deep_research", %{"topic" => "citrus"})},
        %Event.TurnFinished{messages: []}
      ])

      Breeze.Test.focus(session, "log")
      screen(session)
      Breeze.Test.input(session, "t")

      text = screen(session)
      assert text =~ "Tool calls · Enter shows one in full"
      assert text =~ "› 1  ✓ web_search  query=lemonade"
      assert text =~ "2  ◐ deep_research  topic=citrus"

      Breeze.Test.input(session, "Enter")
      text = screen(session)
      assert Breeze.Test.focused(session) == "inspector"
      assert text =~ "1  ✓ web_search  ok"
      assert text =~ ~s("query": "lemonade")
      assert text =~ ~s("hits": 3)
      assert text =~ ~s("top": "stand")
      assert text =~ "inspector · j/k scroll"

      Breeze.Test.input(session, "Escape")
      refute screen(session) =~ ~s("hits": 3)
      assert Breeze.Test.focused(session) == "log"

      emit(turn, [
        %Event.ToolDenied{
          call_id: "call_2",
          name: "deep_research",
          reason: "not during the freeze",
          decided_by: %{by: :default, hooks: []}
        }
      ])

      Breeze.Test.focus(session, "prompt")
      submit(session, "/tools")
      assert screen(session) =~ "2  ✗ deep_research"
      Breeze.Test.input(session, "ArrowDown")
      Breeze.Test.input(session, "Enter")
      text = screen(session)
      assert text =~ "deep_research  failed"
      assert text =~ "not during the freeze"
      Breeze.Test.input(session, "Escape")
      assert Breeze.Test.focused(session) == "prompt"
    end

    test "/tools with none says so on the status row", %{session: session} do
      submit(session, "/tools")

      assert status_row(session) =~ "no tool calls in this conversation yet"
      refute screen(session) =~ "Tool calls ·"
    end

    test "local notices sit on the status row and leave the transcript alone", ctx do
      %{session: session} = ctx
      submit(session, "/filter attention")
      assert status_row(session) =~ "the panel shows 0 of 0 agents matching attention"

      submit(session, "/next")
      assert status_row(session) =~ "no agent needs attention"
      refute screen(session) =~ "the panel shows"

      submit(session, "/confirm")
      assert status_row(session) =~ "nothing is waiting to be confirmed"

      # The transcript above holds only the banner and the commands' echoes.
      transcript = session |> screen() |> String.split("\n") |> Enum.slice(1..7)
      refute Enum.join(transcript, "\n") =~ "no agent needs attention"
    end

    test "the status row names the focused pane", %{session: session} do
      assert status_row(session) =~ "prompt · Ctrl-X pane"
      Breeze.Test.focus(session, "log")
      Breeze.Test.input(session, "j")
      assert status_row(session) =~ "transcript · j/k scroll"
    end
  end

  describe "the activity row" do
    test "is idle between turns", %{session: session} do
      assert screen(session) =~ "idle"
    end

    test "carries a spinner only while a turn runs", %{session: session, turn: turn} do
      screen(session)

      assert Breeze.Test.element(session, "activity") ==
               {:error, {:element_not_found, "activity"}}

      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      screen(session)
      assert {:ok, %Breeze.Viewport{}} = Breeze.Test.element(session, "activity")

      emit(turn, [%Event.TurnFinished{messages: []}])
      screen(session)

      assert Breeze.Test.element(session, "activity") ==
               {:error, {:element_not_found, "activity"}}
    end

    test "a notice takes the row from the spinner while it shows", %{session: session, turn: turn} do
      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}])
      screen(session)

      Breeze.Test.focus(session, "log")
      Breeze.Test.input(session, "y")
      assert screen(session) =~ "nothing to copy"

      assert Breeze.Test.element(session, "activity") ==
               {:error, {:element_not_found, "activity"}}
    end

    test "names the innermost work and the newest reasoning", %{
      session: session,
      turn: turn
    } do
      tool = Source.child(turn, name: "web_search")

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Thinking{text: "I should look this up carefully"}
      ])

      assert screen(session) =~ "turn · I should look this up carefully"

      emit(tool, [%Event.SpanStarted{name: "web_search"}])
      text = screen(session)
      assert text =~ "web_search"
      refute text =~ "idle"
      refute text =~ "look this up"

      emit(tool, [%Event.SpanFinished{outcome: :ok, duration_ms: 10}])

      emit(turn, [
        %Event.ModelStarted{
          message_id: "m0",
          model_spec: "m",
          decided_by: %{by: :default, hooks: []}
        },
        %Event.Thinking{text: " and then decide"}
      ])

      assert screen(session) =~ "turn · I should look this up carefully and then decide"
    end

    test "a chunk ending in a space still separates words", %{session: session, turn: turn} do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Thinking{text: "I should "},
        %Event.Thinking{text: "rank these"}
      ])

      assert screen(session) =~ "turn · I should rank these"
    end

    test "long reasoning shows its newest words, cut at a word and marked", %{
      session: session,
      turn: turn
    } do
      words = Enum.map_join(1..30, " ", &"word#{&1}")

      emit(turn, [%Event.TurnStarted{messages: [Message.new("hi")]}, %Event.Thinking{text: words}])

      [row] = session |> screen() |> String.split("\n") |> Enum.filter(&(&1 =~ "turn ·"))

      assert row =~ ~r/turn · …word\d+ /
      assert row =~ "word30"
    end

    test "reasoning stays off the transcript unless tracing is on", %{
      session: session,
      turn: turn
    } do
      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.Thinking{text: "secret plan\n"}
      ])

      refute screen(session) =~ "┊ secret plan"

      Breeze.Test.input(session, %{"key" => "t", "ctrlKey" => true})
      emit(turn, [%Event.Thinking{text: "open plan\n"}])
      assert screen(session) =~ "┊ open plan"
    end
  end

  describe "the meta row" do
    test "adds up tokens and cost across concurrent requests", %{session: session, turn: turn} do
      branch = Source.child(turn, name: "researcher")

      emit(turn, [
        %Event.TurnStarted{messages: [Message.new("hi")]},
        %Event.ModelStarted{
          message_id: "m0",
          model_spec: "m",
          decided_by: %{by: :default, hooks: []}
        }
      ])

      emit(branch, [
        %Event.ModelStarted{
          message_id: "m0",
          model_spec: "m",
          decided_by: %{by: :default, hooks: []}
        }
      ])

      emit(turn, [
        %Event.Meta{chunk: meta(%{input_tokens: 1_000, output_tokens: 100, total_cost: 0.01})}
      ])

      emit(branch, [
        %Event.Meta{chunk: meta(%{input_tokens: 500, output_tokens: 50, total_cost: 0.005})}
      ])

      refute screen(session) =~ "req"

      emit(turn, [
        %Event.ModelFinished{
          message_id: "m0",
          outcome: :ok,
          duration_ms: 10,
          response: nil,
          cost: nil
        }
      ])

      emit(branch, [
        %Event.ModelFinished{
          message_id: "m0",
          outcome: :ok,
          duration_ms: 10,
          response: nil,
          cost: nil
        }
      ])

      text = screen(session)
      assert text =~ "↑ 1.5k in"
      assert text =~ "↓ 150 out"
      assert text =~ "$0.02"
      assert text =~ "2 req"
    end
  end
end
