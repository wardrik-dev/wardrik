defmodule Wardrik.Views.Runs do
  @moduledoc """
  What an agent's runs did and cost, kept current as its events arrive.

      runs = Wardrik.Views.Runs.fold(events, events: true)
      Wardrik.Views.Runs.runs(runs)
      #=> [%{id: "0af7...", status: :completed, model: "anthropic:claude-haiku-4-5", ...}]

      Wardrik.Views.Runs.totals(runs)
      #=> %{runs: 12, failed: 1, tool_calls: 40, input_tokens: 51_200, output_tokens: 8_300, cost_micro_usd: 91_000, last_at: "..."}

  It takes `Wardrik.Event`s, or events as `Wardrik.run/3` and `Wardrik.stream/3` answer them.
  `Wardrik.Agent.runs/3` answers the same once, as JSON.

  Each run has `:id`, `:status`, `:started_at`, `:finished_at`, `:source` (who started it),
  `:model`, `:tool_calls`, `:tool_errors`, `:input_tokens`, `:output_tokens`, `:cost_micro_usd` and
  `:error`. Its tool calls, tokens and cost include its subagents'.

  ## Options

    * `:events` - `true` to keep each run's events, oldest first, as its `:events`. `false` unless
      set.
  """

  alias WardrikEvents.Runs

  @type t() :: Runs.t()

  @doc "Returns the runs before any event. See the options above."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: Runs.init(opts)

  @doc "Folds `events`, oldest first, into new runs."
  @spec fold(Enumerable.t(), keyword()) :: t()
  def fold(events, opts \\ []), do: Enum.reduce(events, new(opts), &__MODULE__.apply(&2, &1))

  @doc "Folds one more event into `runs`."
  @spec apply(t(), Wardrik.Event.t() | map()) :: t()
  def apply(runs, event), do: Runs.handle_event(Wardrik.Views.json(event), runs)

  @doc "Returns the runs, newest first."
  @spec runs(t()) :: [map()]
  defdelegate runs(runs), to: Runs

  @doc """
  Returns the totals across every run: `:runs`, `:failed`, `:tool_calls`, `:input_tokens`,
  `:output_tokens`, `:cost_micro_usd`, and `:last_at`, when the newest run started.
  """
  @spec totals(t()) :: map()
  defdelegate totals(runs), to: Runs

  @doc "Adds up `totals/1`s, such as an agent's own and its conversations'."
  @spec sum([map()]) :: map()
  defdelegate sum(totals), to: Runs

  @doc "Returns how long `run` took in milliseconds, or `nil` while it runs."
  @spec duration_ms(map()) :: non_neg_integer() | nil
  defdelegate duration_ms(run), to: Runs
end
