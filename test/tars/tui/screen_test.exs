defmodule Tars.TUI.ScreenTest do
  @moduledoc """
  Exercises the real terminal implementation.

  `Tars.TUITest` proves the TUI makes the right calls; this proves those calls
  produce sane bytes — every `Tars.TUI.View` output has to survive
  `Owl.Data.to_chardata/1`, and the status line has to erase itself rather than
  scroll.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Tars.Event
  alias Tars.Event.Source
  alias Tars.TUI.Activity
  alias Tars.TUI.Markdown
  alias Tars.TUI.Screen.Terminal
  alias Tars.TUI.View

  @erase "\r\e[2K"
  @save "\e7"
  @restore "\e8"
  @reset_region "\e[r"
  @show_cursor "\e[?25h"
  @width 80

  defp activity do
    turn = Source.root(:assistant, name: "turn")
    tool = Source.child(turn, name: "web_search")

    Activity.new()
    |> Activity.fold(Event.new(turn, {:turn_started, ["hi"]}), now: 0)
    |> Activity.fold(Event.new(tool, {:span_started, "web_search"}), now: 0)
    |> Activity.fold(Event.new(tool, {:thinking, "pondering"}), now: 0)
  end

  test "write/1 emits text and ends its row" do
    out = capture_io(fn -> Terminal.write(View.answer(Markdown.line("Pong!"))) end)

    assert out == "Pong!\n"
  end

  test "every view output is renderable chardata" do
    activity = activity()

    out =
      capture_io(fn ->
        Terminal.write(View.banner("test-model", true))
        Terminal.write(View.prompt())
        Terminal.write(View.answer(Markdown.line(String.duplicate("x", 500))))
        Terminal.write(View.reasoning(Markdown.line("**pondering** hard")))
        Terminal.write(View.error(:rate_limited))

        for span <- Activity.spans(activity),
            do: Terminal.write(View.span(span, Activity.depth(activity, span.span_id), 1_000))

        Terminal.status(
          View.status(
            %{frame: 3, activity: activity, thinking: "pondering", chars: 340, now: 1_000},
            @width
          ),
          nil
        )

        Terminal.clear_status(nil)
      end)

    assert out =~ "tars"
    assert out =~ "xxx"
    assert out =~ "pondering"
    assert out =~ ":rate_limited"
    assert out =~ "web_search"
    assert out =~ "340 chars"
  end

  describe "with a terminal" do
    test "open/1 reserves the bottom row for the status line" do
      out = capture_io(fn -> Terminal.open(24) end)

      # Rows 1..23 scroll; row 24 is ours.
      assert out =~ "\e[1;23r"
    end

    test "the status line is drawn on that row and the cursor put straight back" do
      out = capture_io(fn -> Terminal.status("working", 24) end)

      assert String.starts_with?(out, @save)
      assert out =~ "\e[24;1H"
      assert out =~ "working"
      assert String.ends_with?(out, @restore)
    end

    test "clear_status/1 empties the row without moving the cursor" do
      out = capture_io(fn -> Terminal.clear_status(24) end)

      assert String.starts_with?(out, @save)
      assert String.ends_with?(out, @restore)
      refute out =~ "\n"
    end

    test "the transcript is written plainly, so it scrolls above the reserved row" do
      out = capture_io(fn -> Terminal.write("an answer\n") end)

      assert out == "an answer\n"
    end

    test "close/1 gives the row back" do
      out = capture_io(fn -> Terminal.close(24) end)

      assert out =~ @reset_region
      assert out =~ @show_cursor
    end
  end

  describe "without a terminal" do
    test "there is no row to reserve" do
      assert capture_io(fn -> Terminal.open(nil) end) == ""
    end

    test "the status line is rewritten in place, which is safe when nobody types" do
      out = capture_io(fn -> Terminal.status("working", nil) end)

      assert out == @erase <> "working"
      refute out =~ "\n"
    end

    test "close/1 still resets, in case a region was ever set" do
      assert capture_io(fn -> Terminal.close(nil) end) == @reset_region <> @show_cursor
    end
  end

  test "a status line never runs past the width it was given" do
    activity = activity()

    out =
      capture_io(fn ->
        Terminal.status(
          View.status(
            %{
              frame: 0,
              activity: activity,
              thinking: String.duplicate("y", 500),
              chars: 1,
              now: 1_000
            },
            @width
          ),
          nil
        )
      end)

    visible = out |> String.replace(@erase, "") |> strip_ansi()

    refute visible =~ "\n"
    assert String.length(visible) <= @width
  end

  test "every verbose trace line renders and ends its own row" do
    payloads = [
      {:turn_started, ["hello"]},
      {:model_started, {:anthropic, model: "x"}},
      {:model_finished, :ok, 1200},
      {:model_finished, {:error, :rate_limited}, 40},
      {:meta, %{tokens: 1}},
      {:tool_started, "call_1", "echo"},
      {:tool_finished, "call_1", "echo", {:ok, "done"}},
      {:tool_finished, "call_2", "boom", {:error, :nope}},
      {:turn_finished, [1, 2]}
    ]

    lines = Enum.map(payloads, &View.trace/1)

    refute Enum.any?(lines, &is_nil/1)

    out = capture_io(fn -> Enum.each(lines, &Terminal.write/1) end)

    assert out =~ "turn"
    assert out =~ "model"
    assert out =~ "echo"

    # Counted rather than split: with ANSI on, Owl closes the whole chardata
    # with a reset that lands after the final newline.
    newlines = length(String.split(out, "\n")) - 1
    assert newlines == Enum.count(payloads)
  end

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;?]*[a-zA-Z]/, "")
end
