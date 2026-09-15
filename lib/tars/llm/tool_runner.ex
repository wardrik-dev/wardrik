defmodule Tars.LLM.ToolRunner do
  @moduledoc """
  Executes model-requested tool calls, each isolated in its own supervised task.

  A tool crash, exit or hang is contained: it becomes an error tool-result
  rather than taking down the turn. Every call is answered with exactly one
  canonical tool-result message, including calls whose task died, which is
  what `ReqLLM.Context.append_tool_exchange/3` requires.

  Each call runs under its own child span, so its events are attributed to
  that call rather than to the turn as a whole. That scope is also published
  through `Tars.Scope.Context`, alongside the call itself, which is how a tool
  that delegates finds its place in the tree and how a tool with an outside
  effect finds an idempotency key.

  Spans are opened by the caller and closed inside the task; a call killed at
  the timeout is closed by the caller instead.

  A batch runs under the longest timeout any tool in it declares, narrowed by
  whatever its scope has left. See `c:Tars.Tool.timeout/0` and
  `Tars.Scope.remaining_ms/1`.

  Tool calls are expected in the normalized shape produced by
  `ReqLLM.Response.classify/1`; see `t:Tars.Tool.call/0`.

  ## Governance

  Before a callback runs, the scope's `Tars.Policy` is asked about the call.
  Three things can happen, and only the first reaches the tool:

    * allowed - the callback runs.
    * denied - the callback never runs and the model is told why, as an
      ordinary tool result. A refusal is an answer, so the turn carries on.
    * asked - the call **parks**. Nothing runs, nothing is appended to the
      conversation, and the batch reports it so the turn can stop and wait for
      a person. See `Tars.Agent.resume/2`.

  ## Stopping one call

  Every call in flight is registered under its agent and call id, so a single
  runaway tool can be stopped without touching the turn around it:

      Tars.LLM.ToolRunner.kill_call("acme/jon/assistant", "call_abc")

  The killed call is answered with an error result the same way a crash is, so
  the model is never left with an unanswered call. `in_flight/1` lists what
  could be stopped.
  """
  alias ReqLLM.Context
  alias Tars.Event
  alias Tars.LLM.Config
  alias Tars.Policy
  alias Tars.Scope
  alias Tars.Tool
  alias Tars.Tool.Result

  @registry __MODULE__.Registry

  @tool_timeout :timer.seconds(60)
  @max_concurrency 8

  @typedoc "What one call did: an answer for the model, or a wait for a person."
  @type outcome() ::
          {:settled, Tool.call(), ReqLLM.Message.t()}
          | {:parked, Tool.call(), String.t()}

  @typedoc "One call in flight, as `in_flight/1` reports it."
  @type running() :: %{
          call_id: String.t(),
          name: String.t(),
          pid: pid(),
          elapsed_ms: non_neg_integer()
        }

  @doc false
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc """
  Runs every call at once and reports what each one did, in call order.

  Returns one `t:outcome/0` per call. Use `messages/1` when nothing can park,
  and `parked/1` to find the calls waiting on a person.
  """
  @spec execute_many_async([Tool.call()], Scope.t()) :: [outcome()]
  def execute_many_async(tool_calls, %Scope{} = scope) do
    Tars.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      Enum.map(tool_calls, &{&1, Scope.open(scope, &1.name)}),
      fn {call, span} -> in_span(call, span, []) end,
      ordered: true,
      max_concurrency: @max_concurrency,
      timeout: timeout(tool_calls, scope),
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, outcome} -> outcome
      {:exit, {{call, span}, reason}} -> reap(call, span, reason)
    end)
  end

  @doc """
  The messages in a batch's outcomes, in order.

  Raises on a parked call, which has no message and never will until it is
  resumed. Call it only where a policy cannot have parked anything.
  """
  @spec messages([outcome()]) :: [ReqLLM.Message.t()]
  def messages(outcomes) when is_list(outcomes) do
    Enum.map(outcomes, fn
      {:settled, _call, message} ->
        message

      {:parked, call, _prompt} ->
        raise ArgumentError, "tool call #{call.id} (#{call.name}) is parked and has no result"
    end)
  end

  @doc "The calls in a batch that parked, each with the prompt a person is shown."
  @spec parked([outcome()]) :: [{Tool.call(), String.t()}]
  def parked(outcomes) when is_list(outcomes) do
    for {:parked, call, prompt} <- outcomes, do: {call, prompt}
  end

  @doc """
  The longest any of `tool_calls` may take.

  The longest timeout any of them declares, never more than the scope has left.
  """
  @spec timeout([Tool.call()], Scope.t()) :: timeout()
  def timeout(tool_calls, %Scope{config: config} = scope) do
    tool_calls
    |> Enum.map(&(Config.tool_timeout(config, &1.name) || @tool_timeout))
    |> Enum.max(fn -> @tool_timeout end)
    |> within(Scope.remaining_ms(scope))
  end

  # A batch admitted with nothing left still gets a moment to answer, so a call
  # that lands exactly on the deadline reports a result rather than a crash.
  defp within(declared, :infinity), do: declared
  defp within(declared, remaining), do: declared |> min(remaining) |> max(1)

  @doc """
  Runs one call and reports what it did.

  Options:

    * `:authorize` - whether to consult the scope's policy, `true` by default.
      A resumed call passes `false`: the decision has already been made, and
      asking again would park it forever.
  """
  @spec execute(Tool.call(), Scope.t(), keyword()) :: outcome()
  def execute(%{name: name} = call, %Scope{} = scope, opts \\ []) do
    in_span(call, Scope.open(scope, name), opts)
  end

  @doc """
  Answers a call a person refused, without running it.

  What `Tars.LLM.Turn.resume/3` uses for a denied call, so a refusal made by a
  person reaches the model in the same shape as one made by a policy.
  """
  @spec refuse(Tool.call(), Scope.t(), String.t()) :: outcome()
  def refuse(%{name: name} = call, %Scope{} = scope, reason) when is_binary(reason) do
    span = Scope.open(scope, name)
    result = deny(call, span, reason)
    Scope.close(span, outcome(result))
    settle(result, call)
  end

  @doc """
  Stops one tool call that is in flight.

  A kill switch for a single call rather than the whole turn: the task running
  it is killed, the model is answered with an error result, and everything else
  the turn asked for carries on.
  """
  @spec kill_call(Event.Bus.agent_id(), String.t()) :: :ok | {:error, :not_found}
  def kill_call(agent_id, call_id) do
    case Registry.lookup(@registry, {agent_id, call_id}) do
      [{pid, _meta}] ->
        Process.exit(pid, :kill)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Every tool call this agent has in flight right now."
  @spec in_flight(Event.Bus.agent_id()) :: [running()]
  def in_flight(agent_id) do
    @registry
    |> Registry.select([
      {{{:"$1", :"$2"}, :"$3", :"$4"}, [{:==, :"$1", {:const, agent_id}}],
       [{{:"$2", :"$3", :"$4"}}]}
    ])
    |> Enum.map(fn {call_id, pid, meta} ->
      %{
        call_id: call_id,
        name: meta.name,
        pid: pid,
        elapsed_ms: Tars.Trace.elapsed_ms(meta.started_at)
      }
    end)
  end

  defp in_span(call, span, opts) do
    span
    |> Scope.closing(&run(call, &1, opts), &outcome/1)
    |> settle(call)
  end

  # A tool that reports its own failure answers the model successfully and the
  # span unsuccessfully: the model gets to correct itself, and a surface gets
  # to say the call did not do its job.
  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome({:parked, _prompt}), do: {:error, :parked}

  defp outcome({:ok, %{"error" => error}} = result) do
    if Result.ok?(result), do: :ok, else: {:error, error}
  end

  defp outcome(_result), do: :ok

  defp settle({:parked, prompt}, call), do: {:parked, call, prompt}
  defp settle({:ok, output}, call), do: {:settled, call, result_message(call, output)}
  defp settle({:error, reason}, call), do: {:settled, call, error_message(call, reason)}

  defp run(call, scope, opts) do
    :ok = Scope.Context.put(scope, call)
    register(scope, call)

    try do
      case decide(call, scope, opts) do
        :allow -> invoke(call, scope)
        {:deny, reason} -> deny(call, scope, reason)
        {:ask, prompt} -> park(call, scope, prompt)
      end
    after
      Registry.unregister(@registry, {scope.source.agent_id, call.id})
    end
  end

  defp decide(call, scope, opts) do
    if Keyword.get(opts, :authorize, true),
      do: Policy.authorize(scope.policy, call, scope),
      else: :allow
  end

  # Registration is best-effort bookkeeping for an operator, so a duplicate id
  # from a provider must not fail the call it belongs to.
  defp register(scope, call) do
    meta = %{name: call.name, started_at: System.monotonic_time()}
    Registry.register(@registry, {scope.source.agent_id, call.id}, meta)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp invoke(%{id: id, name: name, arguments: args}, scope) do
    Event.emit(scope.source, {:tool_started, id, name})

    result =
      case Enum.find(Config.tools(scope.config), &(&1.name == name)) do
        nil -> {:error, "Unknown tool: #{name}"}
        tool -> ReqLLM.Tool.execute(tool, args)
      end

    Event.emit(scope.source, {:tool_finished, id, name, result})

    result
  end

  defp deny(%{id: id, name: name}, scope, reason) do
    Event.emit(scope.source, {:tool_denied, id, name, reason})
    Result.error(:denied, reason)
  end

  defp park(%{id: id, name: name}, scope, prompt) do
    Event.emit(scope.source, {:tool_parked, id, name, prompt})
    {:parked, prompt}
  end

  defp result_message(%{id: id, name: name}, output),
    do: Context.tool_result_message(name, id, output)

  defp reap(%{id: id, name: name} = call, span, reason) do
    Scope.close(span, {:error, reason})
    {:settled, call, error_message(%{id: id, name: name}, "Tool crashed: #{inspect(reason)}")}
  end

  defp error_message(%{id: id, name: name}, reason) when is_binary(reason) do
    Context.tool_result_message(name, id, %{error: reason}, %{is_error: true})
  end

  defp error_message(call, reason), do: error_message(call, message(reason))

  # What the model is told is the sentence, not the struct around it. A schema
  # violation already says which argument was wrong and what was expected;
  # inspecting the error buries that under a stacktrace.
  defp message(%{reason: reason}) when is_binary(reason), do: reason
  defp message(%{__exception__: true} = error), do: Exception.message(error)
  defp message(reason), do: inspect(reason)
end
