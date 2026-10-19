defmodule Wardrik.LLM.ToolRunner do
  @moduledoc """
  Executes model-requested tool calls, each isolated in its own supervised task.

  A tool crash, exit or hang is contained: it becomes an error tool-result
  rather than taking down the turn. The reverse does not hold: a turn that is
  killed takes the calls it has in flight with it. Every call is answered with exactly one
  `Wardrik.Conversation.ToolResult` or `Wardrik.Conversation.ToolError`,
  including calls whose task died, so the model never reads a call left
  unanswered.

  Each call runs under its own child span, so its events are attributed to
  that call rather than to the turn as a whole. A tool is handed a
  `Wardrik.Tool.Context` under that run, which is how a tool that delegates
  finds its place in the tree and how a tool with an outside effect finds an
  idempotency key.

  Spans are opened by the caller and closed inside the task; a call killed at
  the timeout is closed by the caller instead.

  A batch runs under the longest timeout any tool in it declares, narrowed by
  whatever its run has left. See `Wardrik.Tool.Annotations` and
  `Wardrik.Run.remaining_ms/1`.

  Each call is a `Wardrik.Call` to a `Wardrik.Call.Tool`, built from the
  `Wardrik.Conversation.ToolCall` the model asked for (see
  `t:Wardrik.Tool.call/0`), and each comes back as one: `:done`, with its
  `:result`, or `:waiting` on a
  person. A call that comes back holds no run, and `messages/1` gives what
  the model reads of a batch.

  ## Steps

  Every call passes through `Wardrik.Call.Pipeline`: the run's hooks decide
  it, the ledger claims it and the credentials its tool needs are resolved,
  its tool runs it, and the ledger records what it answered. A refusal is an
  answer, so the turn carries on; a call that asks a person **parks**,
  nothing is appended to the conversation, and the batch reports it so the
  turn can stop and wait. See `Wardrik.Agent.resume/2`. An approved call runs
  without the hooks being asked again.

  ## Stopping one call

  Every call in flight is registered under its agent, with its call id, so a single
  runaway tool can be stopped without touching the turn around it:

      Wardrik.LLM.ToolRunner.kill_call(~A"acme/@jon/assistant", "call_abc")

  The killed call is answered with an error result the same way a crash is, so
  the model is never left with an unanswered call. `in_flight/1` lists what
  could be stopped.
  """
  alias Wardrik.Call
  alias Wardrik.Call.Pipeline
  alias Wardrik.Call.Tool
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolError
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias Wardrik.Tool.Result

  @registry __MODULE__.Registry

  @tool_timeout :timer.seconds(60)
  @max_concurrency 8

  @typedoc "One call in flight, as `in_flight/1` reports it."
  @type running() :: %{
          call_id: String.t(),
          name: String.t(),
          pid: pid(),
          elapsed_ms: non_neg_integer()
        }

  @doc false
  def child_spec([]),
    do:
      Registry.child_spec(
        keys: :duplicate,
        name: @registry,
        partitions: System.schedulers_online()
      )

  @doc """
  Runs every call at once and reports what each one did, in call order.

  Returns one `Wardrik.Call` per call. Use `messages/1` when nothing can park,
  and `parked/1` to find the calls waiting on a person.
  """
  @spec execute_many_async([Call.t() | Wardrik.Tool.call()], Run.t()) :: [Call.t()]
  def execute_many_async(tool_calls, %Run{} = run) do
    turn = self()
    index = Config.tool_index(run.config)
    calls = Enum.map(tool_calls, &token/1)

    Wardrik.Tasks.supervisor()
    |> Task.Supervisor.async_stream_nolink(
      Enum.map(calls, &{&1, Run.open(run, Call.name(&1))}),
      fn {call, span} ->
        Wardrik.Tether.to(turn)
        call |> Pipeline.indexed(index) |> in_span(span)
      end,
      ordered: true,
      max_concurrency: @max_concurrency,
      timeout: timeout(calls, run, index),
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, outcome} -> outcome
      {:exit, {{call, span}, reason}} -> reap(call, span, reason)
    end)
  end

  @doc """
  The messages a batch's calls were answered with, in order.

  Raises on a call waiting on a person, which has no message and never will
  until it is resumed. Call it only where nothing can have parked.
  """
  @spec messages([Call.t()]) :: [ToolResult.t() | ToolError.t()]
  def messages(calls) when is_list(calls) do
    Enum.map(calls, fn
      %Call{state: :done, result: {:ok, output}} = call ->
        result_message(call, output)

      %Call{state: :done, result: {:error, reason}} = call ->
        error_message(call, reason)

      %Call{} = call ->
        raise ArgumentError,
              "tool call #{call.id} (#{Call.name(call)}) is parked and has no result"
    end)
  end

  @doc """
  The calls in a batch waiting on a person, each with the prompt a person is
  shown. A call whose tool named where to authorize carries it as `:link`,
  and one that may already have done what it does is marked `in_doubt: true`.
  """
  @spec parked([Call.t()]) :: [{Wardrik.Tool.call(), String.t()}]
  def parked(calls) when is_list(calls) do
    for %Call{state: :waiting} = call <- calls, do: {waiting(call), Call.prompt(call)}
  end

  defp waiting(%Call{} = call) do
    call
    |> Call.to_map()
    |> put_link(Call.link(call))
    |> put_doubt(Call.asked_by?(call, :doubt))
  end

  defp put_link(map, nil), do: map
  defp put_link(map, link), do: Map.put(map, :link, link)

  defp put_doubt(map, true), do: Map.put(map, :in_doubt, true)
  defp put_doubt(map, false), do: map

  @doc """
  The longest any of `tool_calls` may take.

  The longest timeout any of them declares, never more than the run has left.
  """
  @spec timeout([Call.t() | Wardrik.Tool.call()], Run.t()) :: timeout()
  def timeout(tool_calls, %Run{config: config} = run),
    do: timeout(tool_calls, run, Config.tool_index(config))

  defp timeout(tool_calls, %Run{config: config} = run, index) do
    tool_calls
    |> Enum.map(&(Config.tool_timeout(config, tool_name(&1), index) || @tool_timeout))
    |> Enum.max(fn -> @tool_timeout end)
    |> within(Run.remaining_ms(run))
  end

  # A batch admitted with nothing left still gets a moment to answer, so a call
  # that lands exactly on the deadline reports a result rather than a crash.
  defp within(declared, :infinity), do: declared
  defp within(declared, remaining), do: declared |> min(remaining) |> max(1)

  defp tool_name(%Call{} = call), do: Call.name(call)
  defp tool_name(%{name: name}), do: name

  @doc """
  Runs one call and reports what it did.

  An unchecked call is handed to the run's hooks first. An approved one is
  not, since the decision has been made and asking again would park it
  forever, and one approved because it may already have run runs again. A
  refused one is answered with why.
  """
  @spec execute(Call.t() | Wardrik.Tool.call(), Run.t()) :: Call.t()
  def execute(call, %Run{} = run) do
    call = token(call)
    in_span(call, Run.open(run, Call.name(call)))
  end

  @doc """
  Answers a call a person refused, without running it, as
  `Wardrik.LLM.Turn.resume/2` does for a denied call, so a refusal made by a
  person reaches the model in the same shape as one made by a hook. See
  `Wardrik.Call.Pipeline` for a call the ledger holds.
  """
  @spec refuse(Call.t() | Wardrik.Tool.call(), Run.t(), String.t()) :: Call.t()
  def refuse(call, %Run{} = run, reason) when is_binary(reason),
    do: call |> token() |> Call.refuse(reason) |> execute(run)

  @doc """
  Stops one tool call that is in flight.

  A kill switch for a single call rather than the whole turn: the task running
  it is killed, the model is answered with an error result, and everything else
  the turn asked for carries on.
  """
  @spec kill_call(Event.Bus.agent_id(), String.t()) :: :ok | {:error, :not_found}
  def kill_call(agent_id, call_id) do
    case Registry.match(@registry, agent_id, %{call_id: call_id}) do
      [] -> {:error, :not_found}
      running -> Enum.each(running, fn {pid, _meta} -> Process.exit(pid, :kill) end)
    end
  end

  @doc "Every tool call this agent has in flight right now."
  @spec in_flight(Event.Bus.agent_id()) :: [running()]
  def in_flight(agent_id) do
    for {pid, meta} <- Registry.lookup(@registry, agent_id) do
      %{
        call_id: meta.call_id,
        name: meta.name,
        pid: pid,
        elapsed_ms: Wardrik.Trace.elapsed_ms(meta.started_at)
      }
    end
  end

  defp token(%Call{} = call), do: call
  defp token(%{id: _, name: _, arguments: _} = call), do: Call.tool(call)

  defp in_span(call, span) do
    span
    |> Run.closing(&run(call, &1), &outcome/1)
    |> Call.under(nil)
  end

  # A tool that reports its own failure answers the model successfully and the
  # span unsuccessfully: the model gets to correct itself, and a surface gets
  # to say the call did not do its job.
  defp outcome(%Call{state: :waiting}), do: {:error, :parked}
  defp outcome(%Call{result: {:error, reason}}), do: {:error, reason}

  defp outcome(%Call{result: {:ok, %{"error" => error}} = result}) do
    if Result.ok?(result), do: :ok, else: {:error, error}
  end

  defp outcome(%Call{}), do: :ok

  defp run(call, branch) do
    agent_id = branch.source.agent_id
    meta = %{call_id: call.id, name: Call.name(call), started_at: System.monotonic_time()}
    {:ok, _owner} = Registry.register(@registry, agent_id, meta)

    try do
      call |> Call.under(branch) |> Pipeline.run()
    after
      Registry.unregister_match(@registry, agent_id, %{call_id: call.id})
    end
  end

  defp result_message(%Call{id: id, target: %Tool{name: name}, note: note}, output),
    do: %ToolResult{call_id: id, name: name, parts: [%Text{text: text(noted(output, note))}]}

  # A note from whoever approved the call goes in the output itself, which
  # some providers send in place of its text.
  defp noted(output, nil), do: output

  defp noted(output, note)
       when is_map(output) and not is_struct(output) and
              not is_map_key(output, "note"),
       do: Map.put(output, "note", note)

  defp noted(output, note), do: %{"result" => output, "note" => note}

  defp reap(call, span, reason) do
    Run.close(span, {:error, reason})
    Call.answer(call, {:error, "Tool crashed: #{inspect(reason)}"})
  end

  defp error_message(%Call{id: id, target: %Tool{name: name}} = call, reason)
       when is_binary(reason) do
    %ToolError{
      call_id: id,
      name: name,
      parts: [%Text{text: text(noted(%{error: reason}, call.note))}]
    }
  end

  defp error_message(call, reason), do: error_message(call, message(reason))

  # What the model reads of an answer: text as it stands, and anything else
  # written as JSON.
  defp text(output) when is_binary(output), do: output
  defp text(output) when is_map(output) or is_list(output), do: JSON.encode!(output)
  defp text(output), do: to_string(output)

  # What the model is told is the sentence, not the struct around it. A schema
  # violation already says which argument was wrong and what was expected;
  # inspecting the error buries that under a stacktrace.
  defp message(%{reason: reason}) when is_binary(reason), do: reason
  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(reason), do: inspect(reason)
end
