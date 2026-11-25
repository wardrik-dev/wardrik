defmodule Wardrik.Chat.Step do
  @moduledoc """
  One thing an agent does in a run, shown in the thread while it works.

    * `:id` - the same for every update of the step.
    * `:title` - what it does, as `"Thinking"` or `"Running search"`.
    * `:status` - `:running`, `:waiting` on a person, `:done` or `:failed`. A run that ends,
      stops or waits leaves no step running.
    * `:details` - more about it: the model's reasoning, retries, an error. It only grows while
      the step runs. `""` if there is nothing more.
    * `:shown` - how many characters of `:details` an earlier post showed. A chat app whose
      updates add to what it shows posts only `unshown/1`.
    * `:since` - when it started. Show a running step's time from it.
  """

  @enforce_keys [:id, :title, :status, :since]
  defstruct [:id, :title, :status, :since, details: "", shown: 0]

  @type status() :: :running | :waiting | :done | :failed

  @type t() :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          status: status(),
          details: String.t(),
          shown: non_neg_integer(),
          since: DateTime.t()
        }

  @doc """
  Returns how long a step has run at `now`, in a few characters.

      Wardrik.Chat.Step.duration(step, ~U[2026-11-25 10:01:20Z])
      #=> "1m 20s"
  """
  @spec duration(t(), DateTime.t()) :: String.t()
  def duration(%__MODULE__{since: since}, now) do
    seconds = max(DateTime.diff(now, since), 0)

    case div(seconds, 60) do
      0 -> "#{seconds}s"
      minutes -> "#{minutes}m #{rem(seconds, 60)}s"
    end
  end

  @doc """
  Returns the part of the step's details no earlier post showed.

      Wardrik.Chat.Step.unshown(%{step | details: "Checking the calendar.", shown: 9})
      #=> "the calendar."
  """
  @spec unshown(t()) :: String.t()
  def unshown(%__MODULE__{details: details, shown: shown}),
    do: String.slice(details, shown, String.length(details))
end
