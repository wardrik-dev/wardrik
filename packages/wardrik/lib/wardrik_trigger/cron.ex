defmodule WardrikTrigger.Cron do
  @moduledoc """
  A five-field cron expression, read in a time zone, and the times it names.

      {:ok, berlin} = Wardrik.TimeZone.new("Europe/Berlin")
      {:ok, cron} = WardrikTrigger.Cron.parse("0 18 * * 1-5", timezone: berlin)
      WardrikTrigger.Cron.next(cron, ~U[2026-09-24 09:10:00Z])
      #=> {:ok, ~U[2026-09-24 16:00:00Z]}

  The fields are minute (0-59), hour (0-23), day of the month (1-31), month
  (1-12) and day of the week (0-7, where 0 and 7 are Sunday). Each is `*`, a
  number, a range `a-b`, any of those with a step `/n`, or a comma-separated
  list of them. `@hourly`, `@daily`, `@weekly`, `@monthly` and `@yearly` stand
  for the expressions they name.

  Where both the day of the month and the day of the week are restricted, a
  day matching either one matches, as in Vixie cron.

  ## Time zones

  The fields name times on the zone's clock, `Etc/UTC` unless `parse/2` is
  given another, so `0 18 * * *` in `Europe/Berlin` runs at six in the
  evening there in summer and in winter alike. Where the zone's clocks skip
  a time, as 02:30 on the night they go forward, it runs at the first
  instant after the gap, once. Where they repeat one, as 02:30 on the night
  they go back, it runs on the first pass only, so `*/15` makes no run in
  the repeated hour. A duration, as `every: 15m`, counts elapsed time and
  ignores zones.
  """

  alias Wardrik.TimeZone

  @enforce_keys [:source, :timezone, :minutes, :hours, :days, :months, :weekdays, :day_rule]
  defstruct [:source, :timezone, :minutes, :hours, :days, :months, :weekdays, :day_rule]

  @typedoc """
  A parsed expression: the text it came from, the zone it is read in, the
  values each field allows, and whether a day must match the day of the
  month, the day of the week, either, or neither.
  """
  @type t() :: %__MODULE__{
          source: String.t(),
          timezone: TimeZone.t(),
          minutes: MapSet.t(non_neg_integer()),
          hours: MapSet.t(non_neg_integer()),
          days: MapSet.t(pos_integer()),
          months: MapSet.t(pos_integer()),
          weekdays: MapSet.t(non_neg_integer()),
          day_rule: :any | :day | :weekday | :either
        }

  @aliases %{
    "@hourly" => "0 * * * *",
    "@daily" => "0 0 * * *",
    "@weekly" => "0 0 * * 0",
    "@monthly" => "0 0 1 * *",
    "@yearly" => "0 0 1 1 *"
  }

  @fields [minutes: 0..59, hours: 0..23, days: 1..31, months: 1..12, weekdays: 0..7]

  # Enough steps to cross the longest gap an expression can hold, the eight
  # years between two 29ths of February, without looping on one that names
  # no day at all.
  @max_steps 20_000

  @doc """
  Reads `text` in `:timezone`, `Etc/UTC` by default, answering why it does
  not read when it does not.
  """
  @spec parse(String.t(), timezone: TimeZone.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text, opts \\ []) when is_binary(text) do
    source = String.trim(text)
    timezone = Keyword.get_lazy(opts, :timezone, &TimeZone.utc/0)

    with {:ok, fields} <- split(Map.get(@aliases, source, source)),
         {:ok, sets} <- sets(fields),
         cron = build(source, timezone, fields, sets),
         {:ok, _next} <- next(cron, ~U[2000-01-01 00:00:00Z]) do
      {:ok, cron}
    else
      {:error, :never} -> {:error, "#{inspect(source)} names no time that exists"}
      {:error, message} -> {:error, message}
    end
  end

  defp split(text) do
    case String.split(text, ~r/\s+/, trim: true) do
      [_, _, _, _, _] = fields -> {:ok, fields}
      _other -> {:error, "#{inspect(text)} is not five fields: minute hour day month weekday"}
    end
  end

  defp sets(fields) do
    @fields
    |> Enum.zip(fields)
    |> Enum.reduce_while({:ok, %{}}, fn {{name, range}, field}, {:ok, acc} ->
      case field_set(field, range) do
        {:ok, set} -> {:cont, {:ok, Map.put(acc, name, set)}}
        {:error, message} -> {:halt, {:error, "#{name}: #{message}"}}
      end
    end)
  end

  defp build(source, timezone, [_minute, _hour, day, _month, weekday], sets) do
    %__MODULE__{
      source: source,
      timezone: timezone,
      minutes: sets.minutes,
      hours: sets.hours,
      days: sets.days,
      months: sets.months,
      weekdays: MapSet.new(sets.weekdays, &rem(&1, 7)),
      day_rule: day_rule(day == "*", weekday == "*")
    }
  end

  defp day_rule(true, true), do: :any
  defp day_rule(false, true), do: :day
  defp day_rule(true, false), do: :weekday
  defp day_rule(false, false), do: :either

  defp field_set(field, range) do
    field
    |> String.split(",")
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case part_values(part, range) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, MapSet.new(values))}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp part_values(part, range) do
    with {:ok, span, step} <- step(part),
         {:ok, first..last//1} <- span(span, step, range) do
      {:ok, Enum.take_every(first..last, step || 1)}
    end
  end

  defp step(part) do
    case String.split(part, "/") do
      [span] ->
        {:ok, span, nil}

      [span, step] ->
        case number(step) do
          {:ok, n} when n > 0 -> {:ok, span, n}
          _other -> {:error, "#{inspect(part)} does not step by a positive number"}
        end

      _other ->
        {:error, "#{inspect(part)} has more than one step"}
    end
  end

  defp span("*", _step, range), do: {:ok, range}

  defp span(text, step, min..max//1 = range) do
    case String.split(text, "-") do
      # `5/15` runs from 5 to the end of the field, as `5-59/15` would.
      [single] ->
        with {:ok, n} <- within(single, range), do: {:ok, n..if(step, do: max, else: n)}

      [first, last] ->
        with {:ok, a} <- within(first, range),
             {:ok, b} <- within(last, range),
             do: forwards(text, a, b)

      _other ->
        {:error, "#{inspect(text)} is not a number or a range #{min}-#{max}"}
    end
  end

  defp forwards(_text, a, b) when a <= b, do: {:ok, a..b}
  defp forwards(text, _a, _b), do: {:error, "#{inspect(text)} runs backwards"}

  defp within(text, min..max//1) do
    case number(text) do
      {:ok, n} when n >= min and n <= max -> {:ok, n}
      _other -> {:error, "#{inspect(text)} is not a number from #{min} to #{max}"}
    end
  end

  defp number(text) do
    case Integer.parse(text) do
      {n, ""} -> {:ok, n}
      _other -> {:error, "#{inspect(text)} is not a number"}
    end
  end

  @doc """
  The first minute `cron` names after `from`, as an instant in UTC, or
  `{:error, :never}` for an expression naming no day that exists, such as
  the 31st of February.
  """
  @spec next(t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :never}
  def next(%__MODULE__{timezone: timezone} = cron, %DateTime{} = from) do
    start =
      timezone
      |> TimeZone.local(from)
      |> NaiveDateTime.truncate(:second)
      |> Map.put(:second, 0)
      |> NaiveDateTime.add(60)

    seek(cron, start, from, @max_steps)
  end

  defp seek(_cron, _at, _from, 0), do: {:error, :never}

  defp seek(cron, at, from, steps) do
    cond do
      at.month not in cron.months -> seek(cron, next_month(at), from, steps - 1)
      not day?(cron, at) -> seek(cron, next_day(at), from, steps - 1)
      at.hour not in cron.hours -> seek(cron, next_hour(at), from, steps - 1)
      at.minute not in cron.minutes -> seek(cron, NaiveDateTime.add(at, 60), from, steps - 1)
      true -> after_from(cron, at, from, steps)
    end
  end

  # A time the clocks repeat reads as its first pass, which can fall before
  # `from` once the second pass has begun; the search goes on past it.
  defp after_from(cron, at, from, steps) do
    instant = TimeZone.at(cron.timezone, at)

    if DateTime.after?(instant, from),
      do: {:ok, instant},
      else: seek(cron, NaiveDateTime.add(at, 60), from, steps - 1)
  end

  defp day?(%__MODULE__{day_rule: :any}, _at), do: true
  defp day?(%__MODULE__{day_rule: :day} = cron, at), do: at.day in cron.days
  defp day?(%__MODULE__{day_rule: :weekday} = cron, at), do: weekday(at) in cron.weekdays

  defp day?(%__MODULE__{day_rule: :either} = cron, at),
    do: at.day in cron.days or weekday(at) in cron.weekdays

  # 0 for Sunday, as cron counts.
  defp weekday(at), do: at |> Date.day_of_week() |> rem(7)

  defp next_month(at) do
    date = at |> NaiveDateTime.to_date() |> Date.beginning_of_month() |> Date.shift(month: 1)
    NaiveDateTime.new!(date, ~T[00:00:00])
  end

  defp next_day(at), do: NaiveDateTime.new!(Date.add(NaiveDateTime.to_date(at), 1), ~T[00:00:00])

  defp next_hour(at), do: at |> Map.put(:minute, 0) |> NaiveDateTime.add(3600)
end

defimpl WardrikTrigger.Every, for: WardrikTrigger.Cron do
  def next(cron, from) do
    {:ok, at} = WardrikTrigger.Cron.next(cron, from)
    at
  end

  def schedule(cron), do: "#{cron.source} #{cron.timezone}"

  def encode(cron), do: %{"every" => cron.source, "timezone" => to_string(cron.timezone)}
end
