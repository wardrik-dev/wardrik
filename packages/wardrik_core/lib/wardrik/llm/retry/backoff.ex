defmodule Wardrik.LLM.Retry.Backoff do
  @moduledoc """
  Asks a model call that failed again, up to `attempts` times after the
  first, waiting longer each time, and then does what `on_exhausted` says:
  `:ask` a person whether to try again, or `:fail` the turn.

  The wait before the `n`th try again is drawn at random between nothing and
  2^(n-1) seconds, and is at most `max_wait` milliseconds: up to a second,
  then two, then four. Drawn at random, the tries of many agents that failed
  together do not all come back together. Where the failed answer says how
  many seconds to wait in a `Retry-After` header, that wait is taken instead,
  at most `max_wait`. A date there is not read.

  Every failure is asked again but an answer with a 4xx status other than
  408, 425 and 429, which says the request cannot succeed as it is: that one
  goes to `on_exhausted` at once. A timeout, a dropped connection, a stream
  that broke, a 5xx and a rate limit are all asked again.

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
  alias Wardrik.LLM.Request

  def again(backoff, %Request{attempts: [last | _] = attempts}, _opts) do
    response = response(last.reason)

    if length(attempts) > backoff.attempts or refused?(response.status),
      do: backoff.on_exhausted,
      else: {:again, wait(backoff, length(attempts), response), backoff.attempts}
  end

  defp refused?(status), do: status in 400..499 and status not in [408, 425, 429]

  defp wait(backoff, tried, response) do
    case retry_after(response) do
      nil -> :rand.uniform(min(backoff.max_wait, :timer.seconds(2 ** (tried - 1))) + 1) - 1
      seconds -> min(:timer.seconds(seconds), backoff.max_wait)
    end
  end

  # The answer a call failed with, where its error carries one, as ReqLLM's
  # do, or wraps one that does, as a stream that broke wraps its request's.
  defp response(%{status: status} = error) when is_integer(status), do: error
  defp response(%{reason: %{status: status} = response}) when is_integer(status), do: response
  defp response(%{cause: cause}), do: response(cause)
  defp response(_reason), do: %{status: nil}

  defp retry_after(response) do
    Enum.find_value(Map.get(response, :headers) || [], fn {name, value} ->
      with "retry-after" <- String.downcase(name),
           {seconds, ""} when seconds >= 0 <- value |> List.wrap() |> hd() |> Integer.parse(),
           do: seconds,
           else: (_other -> nil)
    end)
  end
end
