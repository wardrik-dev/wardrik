defprotocol WardrikTrigger.Every do
  @moduledoc """
  When a trigger on a clock runs: a `WardrikTrigger.Cron` expression, read
  in its time zone, or a `WardrikTrigger.Interval`, every so many
  milliseconds.
  """

  @doc "The first time it names after `from`, in UTC."
  @spec next(t(), DateTime.t()) :: DateTime.t()
  def next(every, from)

  @doc "When it runs, as a person reads it: `0 18 * * * Europe/Berlin`, or `every 30m`."
  @spec schedule(t()) :: String.t()
  def schedule(every)

  @doc "It written as text, as `WardrikTrigger.decode/3` reads it: `every`, and a cron expression's `timezone`."
  @spec encode(t()) :: %{String.t() => String.t()}
  def encode(every)
end
