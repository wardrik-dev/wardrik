defmodule Tars.Failure do
  @moduledoc """
  What kind of failure a turn hit, so a caller knows whether to try again.

  A dropped provider stream and a malformed tool declaration both arrive as
  `{:error, reason}`, and treating them alike is how one network blip becomes a
  dead conversation. This classifies the reason so the decision is made once,
  from the error itself, rather than guessed at every call site.

      case Tars.LLM.Turn.run(scope, context) do
        {:error, reason} ->
          case Tars.Failure.classify(reason) do
            :transient -> retry(...)
            _terminal -> report(reason)
          end
      end

  ## The classes

    * `:transient` - the same request may well succeed: a timeout, a dropped
      connection, a rate limit, a provider 5xx. Worth retrying.
    * `:ceiling` - a limit did its job: an interrupt, a deadline, an iteration
      cap, a policy refusal. Retrying repeats it, so report it instead.
    * `:bug` - a deterministic fault: a bad schema, a raise in a tool, anything
      unrecognised. Retrying repeats it.

  **Anything unrecognised is a `:bug`.** A failure nobody has classified is
  more likely a fault than a blip, and a retry loop that assumes otherwise
  spends real money discovering it.

  A host with provider errors of its own matches those first and falls back
  here, so its own vocabulary wins without losing this one.
  """

  @typedoc "Whether a failure is worth retrying, and why not when it is not."
  @type class() :: :transient | :ceiling | :bug

  @transient_reasons [
    :timeout,
    :closed,
    :econnrefused,
    :econnreset,
    :ehostunreach,
    :enetunreach,
    :etimedout,
    :nxdomain,
    :socket_closed_remotely,
    :pool_timeout
  ]

  @ceiling_reasons [
    :interrupted,
    :deadline_exceeded,
    :max_iterations,
    :denied,
    :killed
  ]

  @doc """
  Classifies a turn's failure reason.

  Recognises the atoms and tuples the runtime itself produces, the shapes
  `ReqLLM` and `Req` raise, and HTTP statuses carried on an error struct.
  """
  @spec classify(term()) :: class()
  def classify(reason) when reason in @transient_reasons, do: :transient
  def classify(reason) when reason in @ceiling_reasons, do: :ceiling
  def classify({:policy_denied, _reason}), do: :ceiling
  def classify({:deadline_exceeded, _remaining}), do: :ceiling
  def classify({kind, _detail}) when is_atom(kind), do: classify(kind)
  def classify(%{__exception__: true} = error), do: classify_exception(error)
  def classify(_reason), do: :bug

  @doc "Whether a reason is worth trying again."
  @spec retryable?(term()) :: boolean()
  def retryable?(reason), do: classify(reason) == :transient

  # A status on the error is the most reliable signal a provider gives; the
  # module name is the fallback for transport errors that carry none.
  defp classify_exception(error) do
    case status(error) do
      status when is_integer(status) -> classify_status(status)
      nil -> classify_cause(error)
    end
  end

  # An error carrying the reason beneath it, as ReqLLM's stream errors carry
  # `cause: :timeout`, is classified by that reason, and by its module where
  # that reason is not recognised.
  defp classify_cause(%{cause: cause} = error) when not is_nil(cause) do
    case classify(cause) do
      :bug -> classify_module(error.__struct__)
      class -> class
    end
  end

  defp classify_cause(error), do: classify_module(error.__struct__)

  defp status(%{status: status}) when is_integer(status), do: status
  defp status(%{reason: %{status: status}}) when is_integer(status), do: status
  defp status(_error), do: nil

  defp classify_status(408), do: :transient
  defp classify_status(429), do: :transient
  defp classify_status(status) when status >= 500, do: :transient
  defp classify_status(_status), do: :bug

  @transient_modules ~w(Timeout Transport Connection Network Unavailable Overloaded RateLimit)

  defp classify_module(module) do
    name = inspect(module)

    if Enum.any?(@transient_modules, &String.contains?(name, &1)),
      do: :transient,
      else: :bug
  end
end
