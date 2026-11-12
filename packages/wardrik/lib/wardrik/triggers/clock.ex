defmodule Wardrik.Triggers.Clock do
  @moduledoc """
  Computes a trigger's next run from a cron expression in a time zone, or from an interval.

      {:ok, clock} = Wardrik.Triggers.Clock.parse("0 18 * * *")
      Wardrik.Triggers.Clock.next(clock, "Europe/Berlin", ~U[2026-10-22 09:00:00Z])
      #=> ~U[2026-10-22 16:00:00Z]

    * A time skipped by a clock change runs just after the gap.
    * A time repeated by a clock change runs once.
  """

  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @type t() :: {:cron, Crontab.CronExpression.t()} | {:interval, pos_integer()}

  @units %{"s" => 1, "m" => 60, "h" => 3600, "d" => 86_400}
  @shortest 60

  @doc """
  Parses a cron expression, as `"0 9 * * 1"` or `"@daily"`, or an interval of at least a minute,
  as `"30m"`. Units are `s`, `m`, `h` and `d`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(every) when is_binary(every) do
    case Regex.run(~r/^(\d+)([smhd])$/, every) do
      [_every, count, unit] -> interval(String.to_integer(count) * Map.fetch!(@units, unit))
      nil -> cron(every)
    end
  end

  @doc "Returns whether `timezone` names a time zone, as `Europe/Berlin`."
  @spec zone?(String.t()) :: boolean()
  def zone?(timezone), do: match?({:ok, _now}, DateTime.now(timezone, Tz.TimeZoneDatabase))

  @doc "Returns the next run after `from`, in UTC. A cron expression is read in `timezone`."
  @spec next(t(), String.t(), DateTime.t()) :: DateTime.t()
  def next({:interval, seconds}, _timezone, from), do: DateTime.add(from, seconds)

  def next({:cron, expression}, timezone, from) do
    local = from |> DateTime.shift_zone!(timezone, Tz.TimeZoneDatabase) |> DateTime.to_naive()

    minute =
      local |> NaiveDateTime.truncate(:second) |> Map.put(:second, 0) |> NaiveDateTime.add(60)

    {:ok, next} = Scheduler.get_next_run_date(expression, minute)

    next
    |> DateTime.from_naive(timezone, Tz.TimeZoneDatabase)
    |> instant()
    |> DateTime.shift_zone!("Etc/UTC", Tz.TimeZoneDatabase)
  end

  defp interval(seconds) when seconds >= @shortest, do: {:ok, {:interval, seconds}}
  defp interval(_seconds), do: {:error, "an interval is at least a minute"}

  defp cron(every) do
    case Parser.parse(every) do
      {:ok, %{reboot: true}} -> {:error, "@reboot isn't a time"}
      {:ok, expression} -> {:ok, {:cron, expression}}
      {:error, _reason} -> {:error, "#{every} is neither a cron expression nor an interval"}
    end
  end

  defp instant({:ok, datetime}), do: datetime
  defp instant({:gap, _before, first_after}), do: first_after
  defp instant({:ambiguous, first, _second}), do: first
end
