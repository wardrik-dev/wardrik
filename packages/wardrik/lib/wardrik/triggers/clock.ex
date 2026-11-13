defmodule Wardrik.Triggers.Clock do
  @moduledoc """
  Computes a trigger's next run from a cron expression in a time zone, from an interval, or from a
  single time.

      {:ok, clock} = Wardrik.Triggers.Clock.parse("0 18 * * *")
      Wardrik.Triggers.Clock.next(clock, "Europe/Berlin", ~U[2026-10-22 09:00:00Z])
      #=> ~U[2026-10-22 16:00:00Z]

    * A time skipped by a clock change runs just after the gap.
    * A time repeated by a clock change runs once.
  """

  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @type t() ::
          {:cron, Crontab.CronExpression.t()}
          | {:interval, pos_integer()}
          | {:at, DateTime.t() | NaiveDateTime.t()}

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

  @doc """
  Parses a single time, as `"2026-11-17T09:00"`, read in the trigger's time zone, or
  `"2026-11-17T17:00:00Z"` with an offset.
  """
  @spec parse_at(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_at(at) when is_binary(at) do
    seconds = Regex.replace(~r/(T\d\d:\d\d)(?=$|Z|[+-])/, at, "\\1:00")

    case DateTime.from_iso8601(seconds) do
      {:ok, instant, _offset} -> {:ok, {:at, DateTime.truncate(instant, :second)}}
      {:error, :missing_offset} -> local(seconds, at)
      {:error, _reason} -> unread(at)
    end
  end

  def parse_at(at), do: unread(at)

  @doc "Returns whether the clock runs at a single time given with an offset."
  @spec instant?(t()) :: boolean()
  def instant?({:at, %DateTime{}}), do: true
  def instant?(_clock), do: false

  @doc "Returns whether `timezone` names a time zone, as `Europe/Berlin`."
  @spec zone?(String.t()) :: boolean()
  def zone?(timezone), do: match?({:ok, _now}, DateTime.now(timezone, Tz.TimeZoneDatabase))

  @doc """
  Returns the next run after `from`, in UTC. A cron expression or a time without an offset is read
  in `timezone`. A single time that's past returns `nil`.
  """
  @spec next(t(), String.t(), DateTime.t()) :: DateTime.t() | nil
  def next({:interval, seconds}, _timezone, from), do: DateTime.add(from, seconds)

  def next({:at, _at} = clock, timezone, from) do
    at = at(clock, timezone)
    if DateTime.after?(at, from), do: at
  end

  def next({:cron, expression}, timezone, from) do
    local =
      from
      |> DateTime.shift_zone!(timezone, Tz.TimeZoneDatabase)
      |> DateTime.to_naive()

    minute =
      local
      |> NaiveDateTime.truncate(:second)
      |> Map.put(:second, 0)
      |> NaiveDateTime.add(60)

    {:ok, next} = Scheduler.get_next_run_date(expression, minute)

    next
    |> DateTime.from_naive(timezone, Tz.TimeZoneDatabase)
    |> instant()
    |> DateTime.shift_zone!("Etc/UTC", Tz.TimeZoneDatabase)
  end

  @doc "Returns the time a single-time clock runs at, in UTC."
  @spec at(t(), String.t()) :: DateTime.t()
  def at({:at, %DateTime{} = at}, _timezone), do: at

  def at({:at, %NaiveDateTime{} = local}, timezone) do
    local
    |> DateTime.from_naive(timezone, Tz.TimeZoneDatabase)
    |> instant()
    |> DateTime.shift_zone!("Etc/UTC", Tz.TimeZoneDatabase)
  end

  defp local(seconds, at) do
    case NaiveDateTime.from_iso8601(seconds) do
      {:ok, local} -> {:ok, {:at, NaiveDateTime.truncate(local, :second)}}
      {:error, _reason} -> unread(at)
    end
  end

  defp unread(at),
    do: {:error, "#{inspect(at)} is not a time, as 2026-11-17T09:00 or 2026-11-17T17:00:00Z"}

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
