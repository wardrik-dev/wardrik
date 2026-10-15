defmodule WardrikTrigger.Interval do
  @moduledoc """
  A trigger that runs every so many milliseconds, counted from its last
  run: elapsed time, which no time zone or clock change moves.
  """

  @enforce_keys [:ms]
  defstruct [:ms]

  @type t() :: %__MODULE__{ms: pos_integer()}

  @units [{"d", 86_400_000}, {"h", 3_600_000}, {"m", 60_000}, {"s", 1_000}]

  @doc "The interval written in the largest unit that divides it: `30m`, `2h`."
  @spec written(t()) :: String.t()
  def written(%__MODULE__{ms: ms}) do
    {unit, size} = Enum.find(@units, fn {_unit, size} -> rem(ms, size) == 0 end)
    "#{div(ms, size)}#{unit}"
  end

  defimpl WardrikTrigger.Every do
    def next(%{ms: ms}, from), do: DateTime.add(from, ms, :millisecond)

    def schedule(%{ms: ms} = interval) when rem(ms, 1_000) == 0,
      do: "every " <> WardrikTrigger.Interval.written(interval)

    def schedule(%{ms: ms}), do: "every #{ms}ms"

    def encode(interval), do: %{"every" => WardrikTrigger.Interval.written(interval)}
  end
end
