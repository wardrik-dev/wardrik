defmodule TarsTUI.App.Frames do
  @moduledoc """
  Schedules coalesced frames and activity ticks for the root view.
  """
  import Breeze.View, only: [assign: 2]

  @tick 100

  def tick(%{assigns: %{tick_due?: true}} = term), do: term

  def tick(term) do
    Process.send_after(self(), :tick, @tick)
    assign(term, tick_due?: true)
  end

  def frame_due(%{assigns: %{frame_due?: true}} = term), do: term

  def frame_due(%{assigns: %{frame_after: after_ms}} = term) do
    Process.send_after(self(), :frame, after_ms)
    assign(term, frame_due?: true, frame_at: System.monotonic_time(:millisecond) + after_ms)
  end
end
