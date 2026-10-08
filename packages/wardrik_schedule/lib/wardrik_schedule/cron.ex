defmodule WardrikSchedule.Cron do
  @moduledoc """
  A five-field cron expression, read in UTC, and the times it names.

      {:ok, cron} = WardrikSchedule.Cron.parse("*/30 9-17 * * 1-5")
      WardrikSchedule.Cron.next(cron, ~U[2026-09-24 09:10:00Z])
      #=> {:ok, ~U[2026-09-24 09:30:00Z]}

  The fields are minute (0-59), hour (0-23), day of the month (1-31), month
  (1-12) and day of the week (0-7, where 0 and 7 are Sunday). Each is `*`, a
  number, a range `a-b`, any of those with a step `/n`, or a comma-separated
  list of them. `@hourly`, `@daily`, `@weekly`, `@monthly` and `@yearly` stand
  for the expressions they name.

  Where both the day of the month and the day of the week are restricted, a
  day matching either one matches, as in Vixie cron.
  """

  @enforce_keys [:source, :minutes, :hours, :days, :months, :weekdays, :day_rule]
  defstruct [:source, :minutes, :hours, :days, :months, :weekdays, :day_rule]

  @typedoc """
  A parsed expression: the text it came from, the values each field allows,
  and whether a day must match the day of the month, the day of the week,
  either, or neither.
  """
  @type t() :: %__MODULE__{
          source: String.t(),
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

  @doc "Reads `text`, answering why it does not read when it does not."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(text) when is_binary(text) do
    source = String.trim(text)

    with {:ok, fields} <- split(Map.get(@aliases, source, source)),
         {:ok, sets} <- sets(fields),
         cron = build(source, fields, sets),
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

  defp build(source, [_minute, _hour, day, _month, weekday], sets) do
    %__MODULE__{
      source: source,
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
  The first minute `cron` names after `from`, or `{:error, :never}` for an
  expression naming no day that exists, such as the 31st of February.
  """
  @spec next(t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, :never}
  def next(%__MODULE__{} = cron, %DateTime{} = from) do
    start =
      from
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.truncate(:second)
      |> Map.put(:second, 0)
      |> DateTime.add(60)

    seek(cron, start, @max_steps)
  end

  defp seek(_cron, _at, 0), do: {:error, :never}

  defp seek(cron, at, steps) do
    cond do
      at.month not in cron.months -> seek(cron, next_month(at), steps - 1)
      not day?(cron, at) -> seek(cron, next_day(at), steps - 1)
      at.hour not in cron.hours -> seek(cron, next_hour(at), steps - 1)
      at.minute not in cron.minutes -> seek(cron, DateTime.add(at, 60), steps - 1)
      true -> {:ok, at}
    end
  end

  defp day?(%__MODULE__{day_rule: :any}, _at), do: true
  defp day?(%__MODULE__{day_rule: :day} = cron, at), do: at.day in cron.days
  defp day?(%__MODULE__{day_rule: :weekday} = cron, at), do: weekday(at) in cron.weekdays

  defp day?(%__MODULE__{day_rule: :either} = cron, at),
    do: at.day in cron.days or weekday(at) in cron.weekdays

  # 0 for Sunday, as cron counts.
  defp weekday(at), do: at |> Date.day_of_week() |> rem(7)

  defp next_month(at) do
    date = at |> DateTime.to_date() |> Date.beginning_of_month() |> Date.shift(month: 1)
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end

  defp next_day(at) do
    DateTime.new!(Date.add(DateTime.to_date(at), 1), ~T[00:00:00], "Etc/UTC")
  end

  defp next_hour(at), do: at |> Map.put(:minute, 0) |> DateTime.add(3600)
end
