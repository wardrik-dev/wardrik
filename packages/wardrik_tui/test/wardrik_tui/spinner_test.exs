defmodule WardrikTUI.SpinnerTest do
  use ExUnit.Case, async: true

  alias WardrikTUI.Spinner

  defp box, do: BackBreeze.Box.new(style: %{})

  defp state(attrs) do
    {:ok, state, opts} = Spinner.init([], attrs, %{})
    {state, opts}
  end

  test "asks Breeze to animate it, and holds no state of its own" do
    {state, opts} = state(%{:"spinner-active" => true})

    assert state.active? == true
    assert Keyword.fetch!(opts, :rerender_every) > 0
    assert Spinner.handle_modifiers(:root, [], state) == []
  end

  test "an attribute Breeze passed as a string still reads as active" do
    {state, _opts} = state(%{:"spinner-active" => "true"})
    assert state.active?

    {state, _opts} = state(%{})
    refute state.active?
  end

  test "placed, it rests the cell and overlays the glyph where it sits" do
    {state, _opts} = state(%{:"spinner-active" => true})
    layout = %Breeze.Viewport{left: 4, top: 2, width: 1, height: 1}

    assert {:ok, rested, overlays: [%{x: 4, y: 2, content: content}]} =
             Spinner.animate(:root, box(), [], state, %{frame: 0, layout: layout})

    assert rested.content == "·"
    assert content =~ "⣾"
  end

  test "unplaced, the glyph goes in the cell itself, and cycles" do
    {state, _opts} = state(%{:"spinner-active" => true})

    glyphs =
      for frame <- 0..9 do
        Spinner.animate(:root, box(), [], state, %{frame: frame, layout: nil}).content
      end

    assert Enum.count(Enum.uniq(glyphs)) == 8
    assert Enum.at(glyphs, 0) == Enum.at(glyphs, 8)
  end

  test "inactive, and for a child, the cell rests" do
    {state, _opts} = state(%{})

    assert Spinner.animate(:root, box(), [], state, %{frame: 3, layout: nil}).content == "·"
    assert Spinner.animate(:child, box(), [], state, %{frame: 3, layout: nil}).content == "·"
  end
end
