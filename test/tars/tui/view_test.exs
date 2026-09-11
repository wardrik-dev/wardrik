defmodule Tars.TUI.ViewTest do
  use ExUnit.Case, async: true

  alias Tars.TUI.View

  defp plain(data), do: data |> Owl.Data.untag() |> to_string()

  defp sequences(%Owl.Tag{sequences: sequences, data: data}), do: sequences ++ sequences(data)
  defp sequences(list) when is_list(list), do: Enum.flat_map(list, &sequences/1)
  defp sequences(_other), do: []

  test "answer/1 passes text through untouched — no box, no framing" do
    assert View.answer("Pong!") == "Pong!"
  end

  test "prompt/0 is renderable Owl data" do
    assert View.prompt() |> plain() =~ "›"
  end

  describe "banner/2" do
    test "names the model and how to quit" do
      out = View.banner("some-model") |> plain()

      assert out =~ "tars"
      assert out =~ "some-model"
      assert out =~ "/quit"
    end

    test "flags verbose mode" do
      refute View.banner("m", false) |> plain() =~ "verbose"
      assert View.banner("m", true) |> plain() =~ "verbose"
    end
  end

  test "spinner/1 cycles through frames" do
    frames = Enum.map(0..20, &View.spinner/1)

    assert Enum.uniq(frames) |> Enum.count() > 1
    assert View.spinner(0) == View.spinner(10)
  end

  describe "status/2" do
    test "falls back to a thinking label with no reasoning or tools" do
      assert View.status(%{frame: 0, thinking: "", tools: [], chars: 0}, 80) |> plain() =~
               "thinking…"
    end

    test "shows only the last line of reasoning, so it cannot grow" do
      thinking = Enum.map_join(1..50, "\n", &"line #{&1}")

      out =
        View.status(%{frame: 0, thinking: thinking, tools: [], chars: 0}, 80)
        |> plain()

      assert out =~ "line 50"
      refute out =~ "line 49"
    end

    test "clips a long reasoning line to the width" do
      out =
        View.status(
          %{frame: 0, thinking: String.duplicate("y", 500), tools: [], chars: 0},
          40
        )
        |> plain()

      assert String.length(out) <= 40
      assert out =~ "…"
    end

    test "is faded, and led by a spinner frame" do
      # ANSI is stripped when there is no tty, so assert on the tag itself.
      assert View.status(%{frame: 0, thinking: "hmm", tools: [], chars: 0}, 80)
             |> sequences()
             |> Enum.member?(:faint)

      assert View.status(%{frame: 0, thinking: "hmm", tools: [], chars: 0}, 80)
             |> plain() =~ View.spinner(0)
    end

    test "tools take precedence over reasoning, oldest first" do
      out =
        View.status(
          %{
            frame: 0,
            thinking: "ignored",
            tools: [{"second", :running}, {"first", :ok}],
            chars: 0
          },
          80
        )
        |> plain()

      refute out =~ "ignored"
      assert out =~ "✓ first"
      assert out =~ "• second"
      assert :binary.match(out, "first") < :binary.match(out, "second")
    end

    test "marks tool failures" do
      assert View.status(
               %{frame: 0, thinking: "", tools: [{"boom", :error}], chars: 0},
               80
             )
             |> plain() =~ "✗ boom"
    end
  end

  test "error/1 renders the reason in red on its own line" do
    out = View.error(:rate_limited)

    assert plain(out) =~ "✗ :rate_limited"
    assert sequences(out) |> Enum.member?(:red)
  end

  describe "event/2" do
    test "names the event kind and summarises its payload" do
      assert View.event({:turn_started, ["hello"]}, 80) |> plain() =~ "turn_started"
      assert View.event({:turn_started, ["hello"]}, 80) |> plain() =~ "hello"
    end

    test "counts messages on a finished turn rather than dumping them" do
      out = View.event({:turn_finished, [:a, :b]}, 80) |> plain()

      assert out =~ "turn_finished"
      assert out =~ "2 message(s)"
    end

    test "summarises tool results by outcome" do
      assert View.event({:tool_started, "c1", "echo"}, 80) |> plain() =~ "echo c1"
      assert View.event({:tool_finished, "c1", "echo", {:ok, :x}}, 80) |> plain() =~ "echo c1 ok"
      assert View.event({:tool_finished, "c1", "b", {:error, :no}}, 80) |> plain() =~ ":no"
    end

    test "clips a large payload rather than wrapping it" do
      out = View.event({:chunk, String.duplicate("x", 5_000)}, 80) |> plain()

      assert String.length(out) <= 81
      assert out =~ "…"
    end

    test "ends each line so events stack one per row" do
      assert View.event({:meta, %{}}, 80) |> plain() |> String.ends_with?("\n")
    end

    test "colours turn boundaries and failures differently" do
      assert View.event({:turn_started, []}, 80) |> sequences() |> Enum.member?(:cyan)
      assert View.event({:turn_failed, :x}, 80) |> sequences() |> Enum.member?(:red)
      assert View.event({:tool_started, "c", "n"}, 80) |> sequences() |> Enum.member?(:yellow)
    end

    test "handles an unknown event shape" do
      assert View.event({:surprise, 1, 2, 3}, 80) |> plain() =~ "surprise"
    end
  end
end
