defmodule WardrikTUI.App.TermState do
  @moduledoc """
  Small adapters for terminal dimensions and implicit widget state.
  """

  def implicit_state(%{implicit_state: states}, id) do
    case Map.get(states, id) do
      {_module, state} -> state
      nil -> %{}
    end
  end

  def width(%{terminal: %{size: %{width: width}}}) when is_integer(width), do: wrap_width(width)

  def width(_term), do: wrap_width(100)

  # The scroll block keeps one column for its scrollbar and clips inside it.
  def wrap_width(width), do: max(width - 4, 10)
end
