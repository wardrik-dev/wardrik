defmodule TarsTUI.ElapsedTest do
  use ExUnit.Case, async: true

  alias TarsTUI.Elapsed

  defp box, do: BackBreeze.Box.new(style: %{})

  test "asks Breeze to animate it, and holds no state of its own" do
    {:ok, state, opts} = Elapsed.init([], %{:"elapsed-since" => 500, :"elapsed-width" => 7}, %{})

    assert state == %{since: 500, width: 7}
    assert Keyword.fetch!(opts, :rerender_every) > 0
    assert Elapsed.handle_modifiers(:root, [], state) == []
  end

  test "attributes Breeze passed as strings still read as numbers" do
    {:ok, state, _opts} =
      Elapsed.init([], %{:"elapsed-since" => "500", :"elapsed-width" => "7"}, %{})

    assert state == %{since: 500, width: 7}
  end

  test "with nothing to count from, the width falls back to one column" do
    {:ok, state, _opts} = Elapsed.init([], %{}, %{})

    assert state == %{since: nil, width: 1}
  end

  test "animating puts the count in the cell, and leaves a child alone" do
    state = %{since: 1_000, width: 7}

    assert Elapsed.animate(:root, box(), [], state, %{now: 5_000}).content == "    4s "
    assert Elapsed.animate(:child, box(), [], state, %{now: 5_000}) == box()
  end

  describe "text/3" do
    test "counts whole seconds since the reading, right-aligned with a margin" do
      assert Elapsed.text(1_000, 1_000, 7) == "    0s "
      assert Elapsed.text(1_000, 9_400, 7) == "    8s "
      assert Elapsed.text(0, 125_000, 7) == "  125s "
    end

    test "a reading in the future reads as nothing elapsed" do
      assert Elapsed.text(5_000, 1_000, 7) == "    0s "
    end

    test "no reading leaves the columns blank" do
      assert Elapsed.text(nil, 1_000, 7) == "       "
    end

    test "a count too wide for its columns keeps its digits" do
      assert Elapsed.text(0, 1_000_000, 4) == "1000s "
    end
  end
end
