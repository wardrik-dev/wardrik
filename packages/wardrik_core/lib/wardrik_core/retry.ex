defmodule WardrikCore.Retry do
  @moduledoc """
  Retries model calls and tool calls that a retry may fix.

  Application integration fragment. Start the required processes before calling these functions.
  See the [package README](https://github.com/wardrik-dev/wardrik_core#readme) for complete setup.

      WardrikCore.start_agent(
        agent_id: "triage",
        model: "anthropic:claude-haiku-4-5",
        retries: [attempts: 3, max_wait: :timer.seconds(10), on_exhausted: :fail]
      )

  ## Options

    * `:attempts` - retries after the first try. `6` by default.
    * `:max_wait` - the longest wait between tries, in milliseconds. Waits double from 1 second,
      or last as long as a provider's `Retry-After` says. `60_000` by default.
    * `:on_exhausted` - when a model call runs out of retries, `:ask` a person
      (see `WardrikCore.Retry.Exhausted`) or `:fail` the turn. `:ask` by default.

  ## What's retried

    * A model call that raised, such as on a timeout, a rate limit or a 5xx. Not a 4xx other than
      408, 425 and 429.
    * A tool call that raised, crashed or timed out, if its tool is `idempotent` or `read_only`.

  A tool should return `{:error, reason}` when a retry won't help, and raise when it might.
  """

  defmodule Exhausted do
    @moduledoc """
    Why a turn parks once a model call's retries run out.

    Resume with `%{"model" => :approve}` to try again, or `%{"model" => {:deny, reason}}` to fail.
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

  `:transient` returns `nil` to stop. `:announce` is called before each wait. Returns
  `{:ok, answer}`, or `{:spent, answer, tries}`.
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
    wait = min(retry_after(reason) || wait(attempt, settings.max_wait), settings.max_wait)
    announce.(%{attempt: attempt, attempts: settings.attempts, wait_ms: wait, reason: reason})
    Process.sleep(wait)
    tried(settings, fun, transient, announce, attempt + 1)
  end

  # Mint gives headers as a list of pairs, Req as a map of lists.
  defp retry_after(%{headers: headers}) when is_list(headers) or is_map(headers) do
    Enum.find_value(headers, fn
      {"retry-after", [value | _rest]} -> seconds(value)
      {"retry-after", value} when is_binary(value) -> seconds(value)
      _header -> nil
    end)
  end

  defp retry_after(_reason), do: nil

  defp seconds(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> :timer.seconds(seconds)
      _date -> nil
    end
  end

  defp wait(_attempt, 0), do: 0

  defp wait(attempt, max_wait),
    do: :rand.uniform(min(:timer.seconds(2 ** (attempt - 1)), max_wait))
end
