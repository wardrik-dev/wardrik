defmodule TarsTUI.Spinner do
  @moduledoc """
  A `Breeze.Implicit` for the activity glyph.

  Breeze drives it as a decoration: `animate/5` is called every #{200}ms and
  the glyph it returns is patched into the frame already on the screen, so no
  view is rendered to move it.

  The element takes `spinner-active`. Inactive, the cell is left as a dot.
  """

  @behaviour Breeze.Implicit

  # Eight-dot braille, which fills the cell rather than riding its top edge.
  @frames ~w(⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷)
  @every 200
  @resting "·"

  @impl Breeze.Implicit
  def init(_children, root_attrs, last_state) do
    active? = Map.get(root_attrs, :"spinner-active", false) in [true, "true", ""]

    {:ok, Map.put(last_state, :active?, active?), rerender_every: @every}
  end

  @impl Breeze.Implicit
  def handle_modifiers(_type, _flags, _state), do: []

  @impl Breeze.Implicit
  def animate(:root, box, _flags, %{active?: true}, %{frame: frame} = ctx) do
    glyph = Enum.at(@frames, rem(frame, length(@frames)))

    case Map.get(ctx, :layout) do
      %Breeze.Viewport{left: left, top: top} ->
        {:ok, %{box | content: @resting},
         overlays: [%{x: left, y: top, content: styled(box, glyph)}]}

      _unplaced ->
        %{box | content: glyph}
    end
  end

  def animate(_type, box, _flags, _state, _ctx), do: %{box | content: @resting}

  defp styled(%{style: %BackBreeze.Style{} = style}, glyph) do
    BackBreeze.Style.render(style, glyph,
      terminal: %Termite.Terminal{size: %{width: 1, height: 1}}
    )
  end

  defp styled(_box, glyph), do: glyph
end
