defmodule WardrikTUI.ScrollTest do
  use ExUnit.Case, async: false

  alias Wardrik.Event
  alias Wardrik.Event.Source
  alias WardrikTUI.App

  # Forty lines of transcript in a pane that shows seven rows.
  setup do
    agent_id = Wardrik.Test.Fleet.id()
    {:ok, agent} = Wardrik.Test.FakeAgent.start_link(self())

    session =
      Breeze.Test.start!(App,
        size: {60, 14},
        start_opts: [agent: agent, agent_id: agent_id, model: "m"]
      )

    on_exit(fn -> Breeze.Test.stop(session) end)

    turn = Source.root(agent_id, name: "turn")
    Event.emit(turn, %Event.TurnStarted{messages: [Wardrik.Agent.Message.new("hi")]})
    Enum.each(1..40, &Event.emit(turn, %Event.Result{text: "line #{&1}\n"}))
    screen(session)
    Breeze.Test.focus(session, "log")

    {:ok, session: session}
  end

  defp screen(session), do: Breeze.Test.render_text!(session)

  defp first_line(session) do
    session
    |> screen()
    |> String.split("\n")
    |> Enum.find_value(fn row ->
      case Regex.run(~r/line \d+/, row) do
        [line] -> line
        nil -> nil
      end
    end)
  end

  test "starts pinned to the newest row", %{session: session} do
    assert screen(session) =~ "line 40"
  end

  test "ArrowUp and ArrowDown move one row", %{session: session} do
    Breeze.Test.input(session, "ArrowUp")
    assert first_line(session) == "line 33"

    Breeze.Test.input(session, "ArrowDown")
    assert first_line(session) == "line 34"
  end

  test "PageUp and PageDown move a page", %{session: session} do
    Breeze.Test.input(session, "PageUp")
    assert first_line(session) == "line 28"

    Breeze.Test.input(session, "PageDown")
    assert first_line(session) == "line 34"
  end

  test "Home and End go to either end", %{session: session} do
    Breeze.Test.input(session, "Home")
    assert screen(session) =~ "Enter sends"

    Breeze.Test.input(session, "End")
    assert screen(session) =~ "line 40"
  end

  test "the wheel moves three rows per notch, times the repeat", %{session: session} do
    Breeze.Test.wheel(session, "log", :up)
    assert first_line(session) == "line 31"

    Breeze.Test.wheel(session, "log", :up, repeat: 2)

    assert first_line(session) == "line 25"

    Breeze.Test.wheel(session, "log", :down)
    assert first_line(session) == "line 28"
  end

  test "keys that mean nothing here leave the view alone", %{session: session} do
    Breeze.Test.input(session, "x")
    assert screen(session) =~ "line 40"
  end
end
