defmodule TarsTUI.Components.Palette do
  @moduledoc "Presentation of command, help, search, and tool choices."
  use Breeze.Component
  alias TarsTUI.App.PaletteFlow
  alias TarsTUI.View

  # The palette sits centred over the panes, as wide as the terminal allows up
  # to a limit, and as tall as its rows need: the borders, the title, the query
  # and a rule, then the rows.
  @palette_width 72
  @palette_rows 12
  @help_rows 28
  @palette_chrome 5

  # Help takes more room than the palette, and scrolls past what it is given.
  defp palette_size(%{step: :help}, choices, width, height) do
    room = min(@help_rows, max(height - @palette_chrome - 2, 1))
    rows = choices |> length() |> max(1) |> min(room)
    {max(width - 4, 20), min(rows + @palette_chrome, height - 2) |> max(6)}
  end

  defp palette_size(_palette, choices, width, height) do
    rows = choices |> length() |> max(1) |> min(@palette_rows)
    {min(width - 4, @palette_width) |> max(20), min(rows + @palette_chrome, height - 2) |> max(6)}
  end

  defp palette_class(palette, choices, width, height) do
    {w, h} = palette_size(palette, choices, width, height)

    "fixed center width-#{w} height-#{h} layer-50 bg-panel border-rounded border-primary overflow-hidden"
  end

  defp palette_content(%{palette: nil}, _choices, _width, _height), do: ""

  defp palette_content(%{palette: palette}, choices, width, height) do
    {w, h} = palette_size(palette, choices, width, height)
    title = View.palette_title(palette.step, palette.command)
    View.palette(title, palette.query, Enum.map(choices, &row/1), palette.cursor, w, h)
  end

  defp row({kind, text}) when kind in [:header, :blank], do: {kind, text}
  defp row({_value, text}), do: {:row, text}

  attr :palette, :map, required: true
  attr :choices, :list, required: true
  attr :width, :integer, required: true
  attr :height, :integer, required: true

  def palette_box(assigns) do
    assigns =
      assign(assigns,
        count: length(assigns.choices),
        skip: assigns.choices |> PaletteFlow.skipped() |> Enum.join(","),
        class: palette_class(assigns.palette, assigns.choices, assigns.width, assigns.height),
        content: palette_content(assigns, assigns.choices, assigns.width, assigns.height)
      )

    ~H"""
    <box
      id="palette"
      focusable
      br-change="palette"
      br-submit="palette_run"
      implicit={TarsTUI.Palette}
      palette-query={@palette.query}
      palette-cursor={@palette.cursor}
      palette-count={@count}
      palette-skip={@skip}
      class={@class}
    >
      {@content}
    </box>
    """
  end
end
