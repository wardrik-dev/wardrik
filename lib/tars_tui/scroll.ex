defmodule TarsTUI.Scroll do
  @moduledoc """
  A `Breeze.Implicit` for a vertically scrolling transcript.

  Keys: `ArrowUp`/`ArrowDown` move one row, `PageUp`/`PageDown` a page,
  `Home`/`End` to either end. A mouse wheel notch moves `#{3}` rows, times
  the repeat count Breeze attaches to a burst of notches.

  With `scroll-autoscroll="bottom"` on the element, the view stays pinned to
  the newest row until the user scrolls up, and pins again once they scroll
  back to the bottom.
  """

  @behaviour Breeze.Implicit

  alias Breeze.Implicit.Common
  alias Breeze.Viewport

  @wheel_rows 3

  @impl Breeze.Implicit
  def init(_children, root_attrs, last_state) do
    autoscroll = Map.get(root_attrs, :"scroll-autoscroll", Map.get(last_state, :autoscroll))

    state = %{
      offset_y: Map.get(last_state, :offset_y, 0),
      autoscroll: autoscroll,
      pinned_bottom: Map.get(last_state, :pinned_bottom, autoscroll == "bottom")
    }

    {:ok, state, requires_layout_rerender: true}
  end

  @impl Breeze.Implicit
  def handle_event(_type, %{"element" => element} = event, state) do
    viewport = Viewport.from_dimensions(element)

    case target(event, viewport, offset_y(state, viewport)) do
      nil ->
        {:noreply, state}

      offset_y ->
        {:noreply, put_offset(state, Viewport.clamp_scroll_y(offset_y, viewport), viewport)}
    end
  end

  def handle_event(_type, _event, state), do: {:noreply, state}

  defp target(%{"key" => key}, _viewport, offset) when key in ["ArrowDown", "j"], do: offset + 1
  defp target(%{"key" => key}, _viewport, offset) when key in ["ArrowUp", "k"], do: offset - 1
  defp target(%{"key" => "PageDown"}, viewport, offset), do: offset + page(viewport)
  defp target(%{"key" => "PageUp"}, viewport, offset), do: offset - page(viewport)
  defp target(%{"key" => "Home"}, _viewport, _offset), do: 0
  defp target(%{"key" => "End"}, viewport, _offset), do: Viewport.max_scroll_y(viewport)

  defp target(%{"mouse" => %{"button" => "wheel_down"} = mouse}, _viewport, offset) do
    offset + @wheel_rows * Common.wheel_repeat(mouse)
  end

  defp target(%{"mouse" => %{"button" => "wheel_up"} = mouse}, _viewport, offset) do
    offset - @wheel_rows * Common.wheel_repeat(mouse)
  end

  defp target(_event, _viewport, _offset), do: nil

  @impl Breeze.Implicit
  def handle_modifiers(:root, flags, state) do
    [scroll_y: offset_y(state, Keyword.get(flags, :layout_element))]
  end

  def handle_modifiers(:child, _flags, _state), do: []

  defp page(%Viewport{viewport_height: height}), do: max(height - 1, 1)

  defp offset_y(state, nil), do: Map.get(state, :offset_y, 0)

  defp offset_y(%{autoscroll: "bottom", pinned_bottom: true}, %Viewport{} = viewport) do
    Viewport.max_scroll_y(viewport)
  end

  defp offset_y(state, %Viewport{} = viewport) do
    Viewport.clamp_scroll_y(Map.get(state, :offset_y, 0), viewport)
  end

  defp put_offset(state, offset_y, viewport) do
    pinned = state.autoscroll == "bottom" and offset_y >= Viewport.max_scroll_y(viewport)
    %{state | offset_y: offset_y, pinned_bottom: pinned}
  end
end
