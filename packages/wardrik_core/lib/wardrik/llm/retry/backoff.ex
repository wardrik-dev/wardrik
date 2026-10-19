defmodule Wardrik.LLM.Retry.Backoff do
  @moduledoc """
  Asks a model call that failed again, up to `attempts` times after the
  first, waiting longer each time, and then does what `on_exhausted` says:
  `:ask` a person whether to try again, or `:fail` the turn.

  The wait before the `n`th try again is drawn at random between nothing and
  2^(n-1) seconds, and is at most `max_wait` milliseconds: up to a second,
  then two, then four. Drawn at random, the tries of many agents that failed
  together do not all come back together. Where the provider said how many
  seconds to wait, as the error's `retry_after`, that wait is taken instead,
  at most `max_wait`.

  Every failure is asked again but a `Wardrik.LLM.Error` with a 4xx status
  other than 408, 425 and 429, which says the request cannot succeed as it
  is: that one goes to `on_exhausted` at once. A timeout, a dropped
  connection, a stream that broke, a 5xx, a rate limit, and a failure with
  no status at all are all asked again.

      retry = %Wardrik.LLM.Retry.Backoff{attempts: 3, on_exhausted: :fail}
      Wardrik.Fleet.spawn(id, config: config, retry: retry)

  The waits are drawn with `:rand` in the turn's process, so a test that
  seeds it there draws the same waits each time.
  """

  defstruct attempts: 6, max_wait: :timer.seconds(60), on_exhausted: :ask

  @type t() :: %__MODULE__{
          attempts: non_neg_integer(),
          max_wait: non_neg_integer(),
          on_exhausted: :ask | :fail
        }
end

defimpl Wardrik.LLM.Retry, for: Wardrik.LLM.Retry.Backoff do
  alias Wardrik.LLM.Error
  alias Wardrik.LLM.Request

  def again(backoff, %Request{attempts: [last | _] = attempts}, _opts) do
    error = said(last.reason)

    if length(attempts) > backoff.attempts or refused?(error.status),
      do: backoff.on_exhausted,
      else: {:again, wait(backoff, length(attempts), error.retry_after), backoff.attempts}
  end

  # A failure the client did not answer for, as a dispatch's refusal, has no
  # status, and is asked again.
  defp said(%Error{} = error), do: error
  defp said(_reason), do: %Error{}

  defp refused?(status), do: status in 400..499 and status not in [408, 425, 429]

  defp wait(backoff, tried, nil),
    do: :rand.uniform(min(backoff.max_wait, :timer.seconds(2 ** (tried - 1))) + 1) - 1

  defp wait(backoff, _tried, seconds), do: min(:timer.seconds(seconds), backoff.max_wait)
end
