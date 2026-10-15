defmodule Wardrik.TimeZone do
  @moduledoc """
  A time zone, by its IANA name, as `Europe/Berlin`: what a schedule's
  times of day and a budget's days, weeks and months are read in.

      {:ok, berlin} = Wardrik.TimeZone.new("Europe/Berlin")
      Wardrik.TimeZone.local(berlin, ~U[2026-07-01 16:00:00Z])
      #=> ~N[2026-07-01 18:00:00]

  `utc/0`, `Etc/UTC`, is the zone wherever none is named. A zone is only
  made from a name the time zone database knows, so every zone in hand can
  be read in. The database is the `tz` package's, compiled into it and
  updated with it, and handed to each conversion rather than read from the
  application's `:time_zone_database` setting.

  ## Times a clock change skips or repeats

  Where a zone's clocks go forward, a local time in the gap names no
  instant, and where they go back, a local time in the repeated hour names
  two. `at/2` reads the first as the first instant after the gap, and the
  second as its first pass: 02:30 on a night the clocks go from 02:00 to
  03:00 is 03:00, and 02:30 on a night they go from 03:00 back to 02:00 is
  the earlier of the two.
  """

  @enforce_keys [:name]
  defstruct [:name]

  @opaque t() :: %__MODULE__{name: String.t()}

  @database Tz.TimeZoneDatabase

  @doc "The zone named `name`, or why there is none."
  @spec new(term()) :: {:ok, t()} | {:error, String.t()}
  def new(name) when is_binary(name) do
    case DateTime.now(name, @database) do
      {:ok, _now} -> {:ok, %__MODULE__{name: name}}
      {:error, _reason} -> {:error, "#{inspect(name)} is not a time zone"}
    end
  end

  def new(other),
    do: {:error, "a time zone is a name such as Europe/Berlin, got #{inspect(other)}"}

  @doc "`Etc/UTC`."
  @spec utc() :: t()
  def utc, do: %__MODULE__{name: "Etc/UTC"}

  @doc "The wall-clock time in `zone` at the instant `at`."
  @spec local(t(), DateTime.t()) :: NaiveDateTime.t()
  def local(%__MODULE__{name: name}, %DateTime{} = at),
    do: at |> DateTime.shift_zone!(name, @database) |> DateTime.to_naive()

  @doc """
  The instant the wall-clock time `local` names in `zone`, in UTC: past a
  gap where the clocks skip it, and its first pass where they repeat it.
  """
  @spec at(t(), NaiveDateTime.t()) :: DateTime.t()
  def at(%__MODULE__{name: name}, %NaiveDateTime{} = local) do
    instant =
      case DateTime.from_naive(local, name, @database) do
        {:ok, at} -> at
        {:gap, _before, just_after} -> just_after
        {:ambiguous, first, _second} -> first
      end

    DateTime.shift_zone!(instant, "Etc/UTC", @database)
  end

  defimpl String.Chars do
    def to_string(%Wardrik.TimeZone{name: name}), do: name
  end
end
