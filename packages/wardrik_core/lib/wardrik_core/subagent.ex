defmodule WardrikCore.Subagent do
  @moduledoc false

  alias WardrikCore.Context
  alias WardrikCore.Event
  alias WardrikCore.Span
  alias WardrikCore.Subagent.Except
  alias WardrikCore.Subagent.Meter
  alias WardrikCore.Turn

  @type answer() :: %{text: String.t(), labels: [String.t()]}

  @spec run(Context.t(), String.t(), keyword()) ::
          {:ok, answer(), map()} | {:error, term(), map()}
  def run(%Context{} = context, prompt, opts) do
    opts =
      Keyword.validate!(opts, [
        :instructions,
        :capabilities,
        :max_rounds,
        name: "subagent",
        timeout: :infinity,
        except_tools: []
      ])

    span = Span.child(context.span || Span.root())
    meter = :ets.new(__MODULE__, [:public, :duplicate_bag])
    began = System.monotonic_time()

    metered = %Meter{table: meter, parent: context, span: span, name: opts[:name]}

    emit(context, span, :started, %{agent: %{name: opts[:name]}, prompt: prompt})

    outcome =
      context |> within(prompt, span, metered, opts) |> turned(opts[:timeout]) |> answered()

    measured = Meter.total(meter)
    tool_calls = Meter.tool_calls(meter)
    true = :ets.delete(meter)

    ended =
      outcome
      |> outcome_data(opts[:name])
      |> Map.merge(%{duration_ms: ms(began), tool_calls: tool_calls, measurements: measured})

    emit(context, span, ended(outcome), ended)

    with_measured(outcome, measured)
  end

  defp with_measured({:ok, answer}, measured), do: {:ok, answer, measured}
  defp with_measured({:error, reason}, measured), do: {:error, reason, measured}

  defp within(context, prompt, span, metered, opts) do
    %{
      context
      | step: nil,
        response: nil,
        resume: nil,
        checkpoint: nil,
        call_started: nil,
        on_chunk: [],
        events: nil,
        tools: [],
        attributes: %{},
        measurements: %{},
        span: span,
        subagent: opts[:name],
        messages: [ReqLLM.Context.user(prompt)],
        instructions: Keyword.get(opts, :instructions, context.instructions),
        capabilities: capabilities(context, opts),
        middleware: [{Meter, metered} | context.middleware],
        max_rounds: Keyword.get(opts, :max_rounds, context.max_rounds)
    }
  end

  defp turned(context, timeout) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      task = Task.Supervisor.async_nolink(supervisor, fn -> Turn.run(context) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        {:exit, reason} -> {:error, {:exit, reason}}
        nil -> {:error, :timeout}
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  defp capabilities(context, opts) do
    capabilities = Keyword.get(opts, :capabilities, context.capabilities)

    case opts[:except_tools] do
      [] -> capabilities
      names -> [{Except, {capabilities, names}}]
    end
  end

  defp answered({:ok, context}),
    do:
      {:ok,
       %{text: ReqLLM.Response.text(context.response) || "", labels: Context.labels(context)}}

  defp answered({:park, _reason, _context}),
    do: {:error, "It came to a call that waits on a person, which a subagent can't wait on."}

  defp answered({:error, reason}), do: {:error, reason}

  defp ended({:ok, _answer}), do: :completed
  defp ended({:error, _reason}), do: :failed

  defp outcome_data({:ok, answer}, name),
    do: %{agent: %{name: name}, message: ReqLLM.Context.assistant(answer.text)}

  defp outcome_data({:error, reason}, name), do: %{agent: %{name: name}, error: reason}

  @doc false
  @spec emit(Context.t(), WardrikCore.Span.t(), atom(), map()) :: :ok
  def emit(context, span, event, metadata),
    do:
      Event.emit(
        context,
        [:wardrik_core, :subagent, event],
        %{},
        Map.merge(%{agent_id: context.agent_id, span: span}, metadata)
      )

  defp ms(began),
    do: System.convert_time_unit(System.monotonic_time() - began, :native, :millisecond)
end
