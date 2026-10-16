defmodule Wardrik.LLM.Retry.Backoff do
  @moduledoc """
  Asks a model call again after each wait it is given, while the failure is
  one `Wardrik.Failure` calls transient, such as a stream that timed out or a
  provider's 5xx. A call that failed once the provider had begun to answer is
  asked again too, since the next try answers under a message id of its own.

  It is the retry of a scope that names none, with the config's `:retries`
  as its waits, and may be named with waits of its own:

      Wardrik.Fleet.spawn(id, config: config, retry: {Wardrik.LLM.Retry.Backoff, [2_000, 10_000]})
  """

  @behaviour Wardrik.LLM.Retry

  alias Wardrik.Failure
  alias Wardrik.LLM.Request

  @impl Wardrik.LLM.Retry
  def again(%Request{attempts: [last | _] = attempts}, _scope, waits) when is_list(waits) do
    case Enum.at(waits, length(attempts) - 1) do
      wait when is_integer(wait) ->
        if Failure.retryable?(last.reason), do: {:again, wait}, else: :stop

      nil ->
        :stop
    end
  end
end
