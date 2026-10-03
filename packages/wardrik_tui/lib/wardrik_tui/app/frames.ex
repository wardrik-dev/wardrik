defmodule WardrikTUI.App.Frames do
  @moduledoc """
  Schedules coalesced frames and activity ticks for the root view.

  A tick redraws the elapsed times. The status row counts whole seconds and a
  delegation row counts tenths, so a tick comes every `#{100}ms` while a
  delegation is shown under an expanded agent and every `#{1_000}ms` otherwise.
  """
  import Breeze.View, only: [assign: 2]

  @tick 1_000
  @tick_delegating 100

  def tick(%{assigns: %{tick_due?: true}} = term), do: term

  def tick(term) do
    Process.send_after(self(), :tick, interval(term))
    assign(term, tick_due?: true)
  end

  defp interval(%{assigns: %{expanded: expanded}}),
    do: if(MapSet.size(expanded) > 0, do: @tick_delegating, else: @tick)

  def frame_due(%{assigns: %{frame_due?: true}} = term), do: term

  def frame_due(%{assigns: %{frame_after: after_ms}} = term) do
    Process.send_after(self(), :frame, after_ms)
    assign(term, frame_due?: true, frame_at: System.monotonic_time(:millisecond) + after_ms)
  end
end
