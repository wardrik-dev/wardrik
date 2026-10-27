defmodule Wardrik.Retries do
  @moduledoc """
  The middleware that tries a failed model call again: a timeout, a dropped connection, a stream
  that broke, a rate limit, a provider's 5xx. It waits a random while before each try, up to a
  second, then up to two, then four, and so on, never more than `max_wait`. A 4xx answer other than
  408, 425 and 429 says the request can't succeed as it is, so it isn't tried again, nor is a call
  a policy refused.

  It takes `:attempts`, the tries after the first, 6 unless set, `:max_wait`, in seconds, 60 unless
  set, and `:on_exhausted`, what happens once the tries are spent: `:ask`, unless set, waits on a
  person to try again with a fresh set, and `:fail` fails the turn. Each try is announced with
  `[:wardrik, :message, :retrying]`.
  """

  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context
  alias WardrikCore.Resume
  alias WardrikPolicy.Ask

  @attempts 6
  @max_wait 60
  @hopeless [400, 401, 402, 403, 404, 405, 406, 409, 410, 411, 412, 413, 414, 415, 422]

  @impl WardrikCore.Middleware
  def call(%Context{step: :generate} = context, next, opts) do
    case answer(context) do
      {:deny, reason} -> {:error, reason}
      _tried_afresh -> tried(context, next, settings(opts), 1)
    end
  end

  def call(context, next, _opts), do: next.(context)

  defp settings(opts) do
    %{
      attempts: Keyword.get(opts, :attempts, @attempts),
      max_wait: :timer.seconds(Keyword.get(opts, :max_wait, @max_wait)),
      on_exhausted: Keyword.get(opts, :on_exhausted, :ask)
    }
  end

  defp tried(context, next, settings, attempt) do
    with {:error, reason} <- next.(context) do
      retried(context, next, settings, attempt, reason)
    end
  end

  defp retried(context, next, settings, attempt, reason) do
    cond do
      not retryable?(reason) -> {:error, reason}
      attempt > settings.attempts -> exhausted(context, settings, attempt, reason)
      true -> again(context, next, settings, attempt, reason)
    end
  end

  defp again(context, next, settings, attempt, reason) do
    wait = wait(attempt, settings.max_wait)
    emit(context, attempt, settings.attempts, wait, reason)
    Process.sleep(wait)
    tried(context, next, settings, attempt + 1)
  end

  defp wait(_attempt, 0), do: 0

  defp wait(attempt, max_wait),
    do: :rand.uniform(min(:timer.seconds(2 ** (attempt - 1)), max_wait))

  defp exhausted(_context, %{on_exhausted: :fail}, _attempt, reason), do: {:error, reason}

  defp exhausted(context, %{on_exhausted: :ask}, attempt, reason) do
    message = "The model failed #{attempt} times: #{message(reason)}. Try again?"

    {:park, %Ask{interrupt: "model_approval", message: message, labels: Context.labels(context)},
     context}
  end

  defp answer(%Context{resume: %Resume{reason: %Ask{}, input: input}}) when is_map(input),
    do: Map.get(input, "model")

  defp answer(_context), do: nil

  defp retryable?(%{status: status}) when status in @hopeless, do: false
  defp retryable?(%{__exception__: true}), do: true
  defp retryable?({:exit, _reason}), do: true
  defp retryable?(:timeout), do: true
  defp retryable?(_reason), do: false

  defp emit(context, attempt, attempts, wait, reason) do
    WardrikCore.Event.emit(context, [:wardrik, :message, :retrying], %{}, %{
      agent_id: context.agent_id,
      span: context.span,
      message: %{id: message_id(context.span)},
      attempt: attempt,
      attempts: attempts,
      wait_ms: wait,
      error: %{type: type(reason), message: message(reason)}
    })
  end

  defp message_id(%WardrikCore.Span{id: id}), do: "msg_" <> id
  defp message_id(nil), do: "msg_unknown"

  defp type(%{__struct__: module}), do: module |> Module.split() |> List.last()
  defp type(reason), do: inspect(reason)

  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(reason), do: inspect(reason)
end
