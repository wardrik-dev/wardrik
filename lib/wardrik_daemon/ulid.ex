defmodule WardrikDaemon.ULID do
  @moduledoc """
  Makes ULIDs, which sort in the order they were made. See https://github.com/ulid/spec.

      WardrikDaemon.ULID.generate()
      #=> "01JF8X5RQ2M3V9ZK0B7Y4T6WHN"

  It runs as one process, so IDs stay in order across callers.
  """

  use Agent

  @alphabet List.to_tuple(~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ")
  @max_random Bitwise.bsl(1, 80) - 1

  @doc false
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts), do: Agent.start_link(fn -> {0, 0} end, name: __MODULE__)

  @doc "Returns a new ULID, after every one made before it."
  @spec generate() :: String.t()
  def generate do
    Agent.get_and_update(__MODULE__, fn last ->
      made = next(last, System.system_time(:millisecond), random())
      {encode(made), made}
    end)
  end

  @doc """
  Returns the ULID after `last`, as `{time, random}`. A later `time` takes `random`; otherwise `last` plus one.
  """
  @spec next({non_neg_integer(), non_neg_integer()}, non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def next({last_time, _last_random}, time, random) when time > last_time, do: {time, random}

  def next({last_time, last_random}, _time, _random) when last_random < @max_random,
    do: {last_time, last_random + 1}

  def next({last_time, _last_random}, _time, random), do: {last_time + 1, random}

  @doc "Returns `{time, random}` as its 26 characters."
  @spec encode({non_neg_integer(), non_neg_integer()}) :: String.t()
  def encode({time, random}) do
    <<value::130>> = <<0::2, time::48, random::80>>

    for shift <- 125..0//-5,
        into: "",
        do: <<elem(@alphabet, value |> Bitwise.bsr(shift) |> Bitwise.band(31))>>
  end

  defp random do
    <<random::80>> = :crypto.strong_rand_bytes(10)
    random
  end
end
