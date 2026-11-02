defmodule WardrikCore.Telemetry do
  @moduledoc """
  The events an agent emits.

  Each goes to `:telemetry` and to the agent's `WardrikCore.Events` sink, as a
  `WardrikCore.Event`. Every event's metadata has `agent_id`, and
  `conversation`, `nil` for the agent's own history. Below, each event lists its other
  metadata, then its measurements.

  ## Events

    * `[:wardrik_core, :agent, :start]` - `state`
    * `[:wardrik_core, :agent, :stop]` - `reason`
    * `[:wardrik_core, :message, :queued]` - `message`, with its `id` in its metadata. Measures
      `queued`.
    * `[:wardrik_core, :message, :delta]` - `span`, `kind` (`:content` or `:thinking`), and the
      streamed `text`.
    * `[:wardrik_core, :turn, :start]` - `kind`, `span`, the `message_ids` the turn answers, and
      the `metadata` given to `WardrikCore.resume/3`.
    * `[:wardrik_core, :turn, :stop]` - `kind`, `span`, `outcome`, and:
      * `messages` - the messages an answered turn added.
      * `reason` - why a turn parked (as `WardrikCore.parked/1` returns) or failed.
      * `kept` and `dropped` - message counts for an interrupted or timed-out turn.

      Measures `duration`.
    * `[:wardrik_core, :turn, :checkpoint]` - measures `calls`.
    * `[:wardrik_core, :tool_call, :exit]` - `call`, `reason`.
    * `[:wardrik_core, :step, :start]` - `step`, `span`, and `model` for a `:generate` step.
    * `[:wardrik_core, :step, :stop]` - `step`, `span`, `status`, `attributes`, and `response` or
      `reason`. Measures `duration` and what the step measured.
    * `[:wardrik_core, :step, :exception]` - `step`, `span`, `kind`, `reason`, `stacktrace`.
    * `[:wardrik_core, :subagent, :started]` - `span`, `agent`, `prompt`.
    * `[:wardrik_core, :subagent, :progress]` - `span`, `agent`, `call`, `tool_calls`. Emitted as
      each tool call begins.
    * `[:wardrik_core, :subagent, :completed]` - `span`, `agent`, `message`, `duration_ms`,
      `tool_calls`, `measurements`.
    * `[:wardrik_core, :subagent, :failed]` - `span`, `agent`, `error`, `duration_ms`,
      `tool_calls`, `measurements`.

  ## Spans

  A turn's `span` is the root of its trace. It keeps the same span through a park or a restart.
  Each step runs in a child span. See `WardrikCore.Span`.
  """

  alias WardrikCore.Context
  alias WardrikCore.Event
  alias WardrikCore.Span

  @doc false
  @spec span(Context.t(), Context.step(), WardrikCore.Middleware.next()) ::
          WardrikCore.Middleware.result()
  def span(%Context{} = context, step, fun) do
    inner = %{context | step: step, span: child(context, step), attributes: principals(context)}
    start = started(inner, step)

    began = System.monotonic_time()

    Event.emit(
      context,
      [:wardrik_core, :step, :start],
      %{system_time: System.system_time()},
      start
    )

    try do
      result = fun.(inner)
      measured = Map.put(measured(result, context), :duration, System.monotonic_time() - began)

      Event.emit(
        context,
        [:wardrik_core, :step, :stop],
        measured,
        Map.merge(start, ended(result))
      )

      result
    catch
      kind, reason ->
        failed = Map.merge(start, %{kind: kind, reason: reason, stacktrace: __STACKTRACE__})
        duration = %{duration: System.monotonic_time() - began}
        Event.emit(context, [:wardrik_core, :step, :exception], duration, failed)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp started(context, :generate),
    do: %{agent_id: context.agent_id, span: context.span, step: :generate, model: context.model}

  defp started(context, step), do: %{agent_id: context.agent_id, span: context.span, step: step}

  defp principals(context) do
    %{}
    |> put_id("enduser.id", Context.acting_for(context))
    |> put_id("wardrik.agent.principal.id", context.principal)
  end

  defp put_id(attributes, _key, nil), do: attributes
  defp put_id(attributes, key, principal), do: Map.put(attributes, key, principal.id)

  defp child(%Context{span: nil}, _step), do: Span.root()

  defp child(context, {:tool_call, call}) do
    replies = Enum.count(context.messages, &(&1.role == :assistant))
    Span.child(context.span, key: "#{replies}/#{call.id}")
  end

  defp child(context, _step), do: Span.child(context.span)

  defp ended({:ok, context}),
    do: %{status: :ok, response: context.response, attributes: context.attributes}

  defp ended({:park, reason, context}),
    do: %{
      status: :park,
      reason: reason,
      response: context.response,
      attributes: context.attributes
    }

  defp ended({:error, reason}), do: %{status: :error, reason: reason, attributes: %{}}

  defp measured({:ok, after_step}, before), do: gained(after_step, before)
  defp measured({:park, _reason, after_step}, before), do: gained(after_step, before)
  defp measured({:error, _reason}, _before), do: %{}

  defp gained(%Context{measurements: now}, %Context{measurements: before}) do
    now
    |> Map.new(fn {key, amount} -> {key, amount - Map.get(before, key, 0)} end)
    |> Map.reject(fn {_key, amount} -> amount == 0 end)
  end
end
