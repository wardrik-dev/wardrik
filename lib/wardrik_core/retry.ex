defmodule WardrikCore.Retry do
  @moduledoc """
  Retries model calls and tool calls that fail in a way a retry may fix.

      WardrikCore.start_agent(
        agent_id: "triage",
        model: "anthropic:claude-haiku-4-5",
        retries: [attempts: 3, max_wait: :timer.seconds(10), on_exhausted: :fail]
      )

  Before each retry it waits a random time of up to 1 second, then up to 2, then 4, and so on,
  capped at `:max_wait`.

  ## Options

    * `:attempts` - retries after the first try. `6` unless set.
    * `:max_wait` - the longest wait, in milliseconds. `60_000` unless set.
    * `:on_exhausted` - what a model call does once retries run out. `:ask` waits for a person to
      say whether to try again (see `WardrikCore.Retry.Exhausted`). `:fail` fails the turn. `:ask`
      unless set.

  ## What's retried

    * A model call that raised, such as on a timeout, a dropped stream, a rate limit or a 5xx.
      Not a 4xx other than 408, 425 and 429, and not a call middleware refused.
    * A tool call that raised, crashed or timed out, if its tool is `idempotent` or `read_only`.

  So a tool should return `{:error, reason}` for failures a retry won't fix, and raise for those
  it might.
  """

  defmodule Exhausted do
    @moduledoc """
    Why a turn parks once a model call's retries run out.

    Resume with `%{"model" => :approve}` to try again with fresh retries, or
    `%{"model" => {:deny, reason}}` to fail the turn.
    """

    @enforce_keys [:message]
    defstruct [:message, interrupt: "model_approval", labels: []]

    @type t() :: %__MODULE__{message: String.t(), interrupt: String.t(), labels: [String.t()]}
  end

  @attempts 6
  @max_wait :timer.minutes(1)
  @hopeless [400, 401, 402, 403, 404, 405, 406, 409, 410, 411, 412, 413, 414, 415, 422]

  @typedoc "An agent's `:retries`. See the options above."
  @type t() :: keyword()

  @doc """
  Runs `fun`, retrying while `:transient` returns a reason for its answer.

      WardrikCore.Retry.run([attempts: 3], fn -> fetch(url) end,
        transient: &transient/1,
        announce: &IO.inspect(&1, label: "retrying")
      )

  `:transient` returns `nil` for an answer that shouldn't be retried. `:announce` is called before
  each wait. Returns `{:ok, answer}`, or `{:spent, answer, tries}` once retries run out.
  """
  @spec run(t(), (-> answer),
          transient: (answer -> term() | nil),
          announce: (map() -> any())
        ) :: {:ok, answer} | {:spent, answer, pos_integer()}
        when answer: term()
  def run(retries, fun, args) do
    transient = Keyword.fetch!(args, :transient)
    announce = Keyword.fetch!(args, :announce)
    tried(settings(retries), fun, transient, announce, 1)
  end

  @doc "Returns the number of retries after the first try."
  @spec attempts(t()) :: non_neg_integer()
  def attempts(retries), do: Keyword.get(retries, :attempts, @attempts)

  @doc "Returns what a model call does once retries run out: `:ask` or `:fail`."
  @spec on_exhausted(t()) :: :ask | :fail
  def on_exhausted(retries), do: Keyword.get(retries, :on_exhausted, :ask)

  @doc "Returns whether a model call that failed with `reason` may succeed on retry."
  @spec transient?(term()) :: boolean()
  def transient?(%{status: status}) when status in @hopeless, do: false
  def transient?(%{__exception__: true}), do: true
  def transient?({:exit, _reason}), do: true
  def transient?(:timeout), do: true
  def transient?(_reason), do: false

  defp settings(retries),
    do: %{attempts: attempts(retries), max_wait: Keyword.get(retries, :max_wait, @max_wait)}

  defp tried(settings, fun, transient, announce, attempt) do
    answer = fun.()

    case transient.(answer) do
      nil -> {:ok, answer}
      _reason when attempt > settings.attempts -> {:spent, answer, attempt}
      reason -> again(settings, fun, transient, announce, attempt, reason)
    end
  end

  defp again(settings, fun, transient, announce, attempt, reason) do
    wait = wait(attempt, settings.max_wait)
    announce.(%{attempt: attempt, attempts: settings.attempts, wait_ms: wait, reason: reason})
    Process.sleep(wait)
    tried(settings, fun, transient, announce, attempt + 1)
  end

  defp wait(_attempt, 0), do: 0

  defp wait(attempt, max_wait),
    do: :rand.uniform(min(:timer.seconds(2 ** (attempt - 1)), max_wait))
end
