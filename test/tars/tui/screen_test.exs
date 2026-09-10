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

  alias Tars.TUI.Screen.Terminal
  alias Tars.TUI.View

  @erase "\r\e[2K"
  @width 80

  test "write/1 emits text with no cursor movement of its own" do
    out = capture_io(fn -> Terminal.write(View.answer("Pong!")) end)

    assert out == "Pong!"
  end

  test "every view output is renderable chardata" do
    out =
      capture_io(fn ->
        Terminal.write(View.banner("test-model", true))
        Terminal.write(View.prompt())
        Terminal.write(View.answer(String.duplicate("x", 500)))
        Terminal.write(View.error(:rate_limited))

        Terminal.status(
          View.status(%{frame: 3, thinking: "pondering", tools: [], chunks: 0, chars: 0}, @width)
        )

        Terminal.status(
          View.status(
            %{frame: 4, thinking: "", tools: [{"echo", :ok}], chunks: 12, chars: 340},
            @width
          )
        )

        Terminal.clear_status()
      end)

    assert out =~ "tars"
    assert out =~ "Pong" or out =~ "xxx"
    assert out =~ ":rate_limited"
    assert out =~ "pondering"
    assert out =~ "echo"
    assert out =~ "12 chunks"
  end

  test "status/1 erases the line before rewriting, so it never scrolls" do
    out = capture_io(fn -> Terminal.status("working") end)

    assert String.starts_with?(out, @erase)
    refute out =~ "\n"
  end

  test "clear_status/1 leaves the line empty" do
    assert capture_io(fn -> Terminal.clear_status() end) == @erase
  end

  test "every verbose event line renders and ends its own row" do
    events = [
      {:turn_started, ["hello"]},
      {:chunk, %{type: :content, text: "hi"}},
      {:thinking, "pondering"},
      {:result, "hi"},
      {:tool_started, "call_1", "echo"},
      {:tool_finished, "call_1", "echo", {:ok, "done"}},
      {:tool_finished, "call_2", "boom", {:error, :nope}},
      {:turn_failed, :rate_limited},
      {:turn_finished, [1, 2]}
    ]

    out = capture_io(fn -> Enum.each(events, &Terminal.write(View.event(&1, @width))) end)

    assert out =~ "turn_started"
    assert out =~ "tool_finished"
    assert out |> String.split("\n", trim: true) |> Enum.count() == Enum.count(events)
  end
end
