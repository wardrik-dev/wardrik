defmodule Wardrik.Event.Log.Entry do
  @moduledoc """
  One event as a reader of `Wardrik.Event.Log` takes it.

  `log` is the log it is in: the agent, by its ID, or `:audit`. `event` is
  the CloudEvent, a map with string keys. `sequence` is its number in the
  log, or `nil` for a live event, which is never written. `follows` is the
  number of the durable event before it, so a live event says where in the
  log it falls.

  A reader that has read the log through sequence `n` takes the entries that
  `follows?/2` it, and so sees every event once, in order. `Wardrik.cursor/2`
  moves a reader's cursor past one.
  """

  @enforce_keys [:log, :event, :follows]
  defstruct [:log, :event, :sequence, :follows]

  @type t() :: %__MODULE__{
          log: Wardrik.Event.Log.log(),
          event: map(),
          sequence: pos_integer() | nil,
          follows: non_neg_integer()
        }

  @doc """
  `events` of `log`, as a read of the log answers them for a read
  after the sequence number `starting_after`, as entries: each durable,
  numbered in turn from the one after it.
  """
  @spec numbered([map()], Wardrik.Event.Log.log(), non_neg_integer()) :: [t()]
  def numbered(events, log, starting_after) do
    events
    |> Enum.with_index(starting_after + 1)
    |> Enum.map(fn {event, sequence} ->
      %__MODULE__{log: log, event: event, sequence: sequence, follows: sequence - 1}
    end)
  end

  @doc "Whether an entry comes after the log read through `sequence`."
  @spec follows?(t(), non_neg_integer()) :: boolean()
  def follows?(%__MODULE__{follows: follows}, sequence), do: follows >= sequence
end
