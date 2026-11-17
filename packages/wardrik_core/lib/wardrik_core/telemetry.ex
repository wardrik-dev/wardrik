defmodule WardrikCore.Telemetry do
  @moduledoc """
  The events an agent emits, to `:telemetry` and to its `WardrikCore.Events` module.

  Every event's metadata has `agent_id` and `conversation`. Each line lists the other metadata,
  then the measurements.

  ## Events

    * `[:wardrik_core, :agent, :start]` - `state`
    * `[:wardrik_core, :agent, :stop]` - `reason`
    * `[:wardrik_core, :message, :queued]` - `message`. Measures `queued`.
    * `[:wardrik_core, :message, :delta]` - `span`, `kind` (`:content` or `:thinking`), `text`.
    * `[:wardrik_core, :turn, :start]` - `kind`, `span`, `message_ids`, and the `metadata` given to
      `WardrikCore.resume/3`.
    * `[:wardrik_core, :turn, :stop]` - `kind`, `span`, `outcome`, and `messages` added, `reason`
      it parked or failed, or `kept` and `dropped` when interrupted. Measures `duration`.
    * `[:wardrik_core, :turn, :checkpoint]` - measures `calls`.
    * `[:wardrik_core, :tool_call, :exit]` - `call`, `reason`.
    * `[:wardrik_core, :step, :start]` - `step`, `span`, and `model` for `:generate`.
    * `[:wardrik_core, :step, :stop]` - `step`, `span`, `status`, `attributes`, and `response` or
      `reason`. Measures `duration` and what the step measured, less what its own steps' events
      report (`Wardrik.Context.add_reported/2`). A `WardrikCore.evaluate/2` call is the step
      `{:evaluate, model}`, with its answers as `response`.
    * `[:wardrik_core, :step, :exception]` - `step`, `span`, `kind`, `reason`, `stacktrace`.
    * `[:wardrik_core, :subagent, :started]` - `span`, `agent`, `prompt`.
    * `[:wardrik_core, :subagent, :progress]` - `span`, `agent`, `call`, `tool_calls`.
    * `[:wardrik_core, :subagent, :completed]` - `span`, `agent`, `message`, `duration_ms`,
      `tool_calls`, `measurements`.
    * `[:wardrik_core, :subagent, :failed]` - `span`, `agent`, `error`, `duration_ms`,
      `tool_calls`, `measurements`.
  """

  alias Wardrik.Context
  alias WardrikCore.Event
  alias WardrikCore.Span

  @doc false
  @spec span(Context.t(), Context.step(), Wardrik.Middleware.next()) ::
          Wardrik.Middleware.result()
  def span(%Context{} = context, step, fun) do
    inner = %{context | step: step, span: child(context, step), attributes: principals(context)}
    start = start(inner, step)

    began = System.monotonic_time()

    Event.emit(
      context,
      [:wardrik_core, :step, :start],
      %{system_time: System.system_time()},
      start
    )

    try do
      result = fun.(inner)

      measured =
        result
        |> measure(context)
        |> Map.put(:duration, System.monotonic_time() - began)

      Event.emit(
        context,
        [:wardrik_core, :step, :stop],
        measured,
        Map.merge(start, finish(result))
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

  defp start(context, :generate),
    do: %{agent_id: context.agent_id, span: context.span, step: :generate, model: context.model}

  defp start(context, step), do: %{agent_id: context.agent_id, span: context.span, step: step}

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

  defp finish({:ok, context}),
    do: %{status: :ok, response: context.response, attributes: context.attributes}

  defp finish({:park, reason, context}),
    do: %{
      status: :park,
      reason: reason,
      response: context.response,
      attributes: context.attributes
    }

  defp finish({:error, reason}), do: %{status: :error, reason: reason, attributes: %{}}

  defp measure({:ok, after_step}, before), do: compute_gain(after_step, before)
  defp measure({:park, _reason, after_step}, before), do: compute_gain(after_step, before)
  defp measure({:error, _reason}, _before), do: %{}

  defp compute_gain(%Context{measurements: now}, %Context{measurements: before}) do
    now
    |> Map.new(fn {key, amount} -> {key, amount - Map.get(before, key, 0)} end)
    |> Context.drop_reported()
    |> Map.reject(fn {_key, amount} -> amount == 0 end)
  end
end
