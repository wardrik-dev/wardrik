defmodule WardrikTUI.App.EditorTest do
  use ExUnit.Case, async: false

  alias WardrikTUI.App

  # The editor is a function the view is started with. This one reports the
  # draft it was given and who is running it, then waits to be told what to
  # answer, so a test drives both ends.
  setup do
    test = self()
    {:ok, agent} = Wardrik.Test.FakeAgent.start_link(test)

    editor = fn draft, context ->
      send(test, {:editing, draft, context, self()})

      receive do
        {:answer, result} -> result
      end
    end

    session =
      Breeze.Test.start!(App,
        size: {70, 14},
        start_opts: [
          agent: agent,
          host: Wardrik.Host.new(store: Wardrik.Test.store(), issuer: %WardrikTUI.Test.Root{}),
          agent_id: Wardrik.Test.Fleet.id(),
          model: "test:model",
          sidebar: false,
          editor: editor
        ],
        global_keybindings: App.keybindings()
      )

    on_exit(fn -> Breeze.Test.stop(session) end)
    Breeze.Test.render_text!(session)

    {:ok, session: session}
  end

  defp screen(session), do: Breeze.Test.render_text!(session)

  defp type(session, text) do
    Enum.each(String.graphemes(text), &Breeze.Test.input(session, &1))
    session
  end

  defp ctrl(session, letter),
    do: Breeze.Test.input(session, %{"key" => letter, "ctrlKey" => true})

  # Answers the editor and waits for it to finish, so the view has heard from
  # it before the next frame is asked for.
  defp answer(pid, result) do
    ref = Process.monitor(pid)
    send(pid, {:answer, result})
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "Ctrl-G opens the draft, and what is saved comes back unsent", %{session: session} do
    type(session, "rough draft")
    ctrl(session, "g")

    assert_receive {:editing, "rough draft", %{terminal: %Termite.Terminal{}}, editor}
    assert screen(session) =~ "editing the prompt · the screen returns when the editor closes"

    answer(editor, {:ok, "polished draft"})

    text = screen(session)
    assert text =~ "› polished draft"
    refute text =~ "editing the prompt"
    refute_receive {:"$gen_cast", {:ask, _text}}

    # The cursor is at the end of what came back.
    type(session, "!")
    assert screen(session) =~ "› polished draft!"
  end

  test "Ctrl-G works from another pane and returns focus to the prompt", %{session: session} do
    type(session, "draft")
    Breeze.Test.focus(session, "log")
    ctrl(session, "g")

    assert_receive {:editing, "draft", _context, editor}
    answer(editor, {:ok, "draft"})
    assert Breeze.Test.focused(session) == "prompt"
  end

  test "an editor that fails leaves the draft as it was and says why", %{session: session} do
    type(session, "kept")
    ctrl(session, "g")
    assert_receive {:editing, "kept", _context, editor}
    answer(editor, {:error, :no_editor})

    text = screen(session)
    assert text =~ "no editor · set $VISUAL or $EDITOR"
    assert text =~ "› kept"

    ctrl(session, "g")
    assert_receive {:editing, "kept", _context, editor}
    answer(editor, {:error, {:exit, 1}})

    text = screen(session)
    assert text =~ "the editor exited with status 1 · the prompt is as it was"
    assert text =~ "› kept"
  end

  test "a second Ctrl-G while the editor is open does nothing", %{session: session} do
    ctrl(session, "g")
    assert_receive {:editing, "", _context, editor}

    ctrl(session, "g")
    refute_receive {:editing, _draft, _context, _pid}

    answer(editor, {:ok, "once"})
    assert screen(session) =~ "› once"
  end
end
