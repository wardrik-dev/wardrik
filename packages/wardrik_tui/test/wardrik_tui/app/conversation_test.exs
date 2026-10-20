defmodule WardrikTUI.App.ConversationTest do
  use ExUnit.Case, async: true

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias Wardrik.Bus

  alias Wardrik.Bus.Event
  alias Wardrik.Bus.Source
  alias WardrikTUI.App.Conversation
  alias WardrikTUI.Transcript

  @options [now: 123, verbose?: false, pinned?: true]

  test "a terminal-free projection renders only the root answer and flushes its last line" do
    root = Source.root(~A"test/assistant", name: "turn")
    child = Source.child(root, name: "research")

    state =
      Conversation.new(60)
      |> Conversation.apply_event(
        Event.new(root, %Bus.TurnStarted{messages: [Wardrik.Agent.Message.new("hello")]}),
        @options
      )

    assert state.running?
    assert state.started_at == 123

    state =
      state
      |> Conversation.apply_event(
        Event.new(child, %Bus.Result{text: "private child answer"}),
        @options
      )
      |> Conversation.apply_event(
        Event.new(root, %Bus.Result{text: "visible answer"}),
        @options
      )

    assert state.answer_text == "visible answer"
    assert state.chars == String.length("visible answer")
    assert Transcript.to_list(state.transcript) == []

    state =
      Conversation.apply_event(
        state,
        Event.new(root, %Bus.TurnFinished{messages: []}),
        @options
      )

    text = state.transcript |> Transcript.to_list() |> Enum.join("\n")

    refute state.running?
    assert text =~ "visible answer"
    refute text =~ "private child answer"
    assert state.unread == 0
    refute_received :tick
    refute_received :frame
  end

  test "unread rows depend on the supplied scroll position" do
    state = Conversation.new(60)
    scrolled = Keyword.put(@options, :pinned?, false)

    state = Conversation.append_lines(state, ["first", "second"], scrolled)
    assert state.unread == 2

    state = Conversation.append(state, "third", @options)
    assert state.unread == 2
    assert Transcript.to_list(state.transcript) == ["first", "second", "third"]
  end

  test "restoring a display preserves the draft without overwriting the current snapshot" do
    saved = %{
      Conversation.new(60)
      | generation: :old_generation,
        trace_id: :old_trace,
        running?: true,
        draft: "unfinished",
        scroll: %{offset_y: 12},
        prompt: %{cursor: 4}
    }

    restored = Conversation.restored_assigns(saved)
    assert restored.draft == "unfinished"

    for field <- [:generation, :trace_id, :activity, :running?, :scroll, :prompt] do
      refute Map.has_key?(restored, field)
    end

    assert saved.scroll == %{offset_y: 12}
    assert saved.prompt == %{cursor: 4}
  end
end
