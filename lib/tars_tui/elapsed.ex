defmodule TarsTUI.Elapsed do
  @moduledoc """
  A `Breeze.Implicit` for how long the running turn has been going.

  Breeze drives it as a decoration: `animate/5` is called every #{1_000}ms and
  the count it returns is patched into the frame already on the screen, so no
  view is rendered to advance it.

  The element takes `elapsed-since`, a `System.monotonic_time(:millisecond)`
  reading, and `elapsed-width`, the columns the count is right-aligned in. With
  no reading the cell stays blank.
  """

  @behaviour Breeze.Implicit

  @every 1_000

  @doc "The count as it reads `now`, right-aligned in `width` columns."
  @spec text(integer() | nil, integer(), pos_integer()) :: String.t()
  def text(nil, _now, width), do: String.duplicate(" ", width)

  def text(since, now, width),
    do: String.pad_leading("#{div(max(now - since, 0), 1_000)}s ", width)

  @impl Breeze.Implicit
  def init(_children, root_attrs, last_state) do
    state = %{
      since: integer(Map.get(root_attrs, :"elapsed-since")),
      width: integer(Map.get(root_attrs, :"elapsed-width")) || 1
    }

    {:ok, Map.merge(last_state, state), rerender_every: @every}
  end

  @impl Breeze.Implicit
  def handle_modifiers(_type, _flags, _state), do: []

  @impl Breeze.Implicit
  def animate(:root, box, _flags, %{since: since, width: width}, %{now: now}),
    do: %{box | content: text(since, now, width)}

  def animate(_type, box, _flags, _state, _ctx), do: box

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_binary(value), do: String.to_integer(value)
  defp integer(_value), do: nil
end
