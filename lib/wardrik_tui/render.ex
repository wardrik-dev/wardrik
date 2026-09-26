defmodule WardrikTUI.Render do
  @moduledoc """
  ANSI strings for the single-row boxes: header, activity and meta.
  """

  alias WardrikTUI.Text

  @doc "One row of ANSI text, without a trailing newline."
  @spec line(Text.t()) :: String.t()
  def line(data), do: data |> Text.to_ansi() |> String.trim_trailing("\n")

  @doc "Plain text, dimmed."
  @spec dim(String.t()) :: String.t()
  def dim(text), do: line(Text.tag(text, :faint))

  @doc "Plain text in one ANSI colour or attribute, such as `:cyan` or `:bright`."
  @spec tag(String.t(), atom() | [atom()]) :: String.t()
  def tag(text, sequence), do: line(Text.tag(text, sequence))

  @doc """
  One row with `left` at the left edge and `right` at the right edge.

  `right` is kept whole; `left` is clipped to the room that remains.
  """
  @spec justify(Text.t(), Text.t(), pos_integer()) :: Text.t()
  def justify(left, right, width) do
    right_width = Text.length(right)
    room = max(width - right_width - 1, 1)
    left = Text.truncate(left, room)
    gap = max(width - Text.length(left) - right_width, 1)

    [left, String.duplicate(" ", gap), right]
  end

  @doc "`text` with every run of whitespace collapsed to one space."
  @spec squash(String.t()) :: String.t()
  def squash(text), do: text |> String.split(~r/\s+/, trim: true) |> Enum.join(" ")
end
