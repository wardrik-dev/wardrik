defmodule Tars.LLM.ToolRunner do
  @moduledoc """
  Executes model-requested tool calls, each isolated in its own supervised task.

  A tool crash, exit or hang is contained: it becomes an error tool-result
  rather than taking down the turn. The reverse does not hold: a turn that is
  killed takes the calls it has in flight with it. Every call is answered with exactly one
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

  Each call is a `Tars.Call` to a `Tars.Call.Tool`, built from the normalized
  shape `ReqLLM.Response.classify/1` produces (see `t:Tars.Tool.call/0`), and
  each comes back as one: `:done`, with its `:result`, or `:waiting` on a
  person. A call that comes back holds no scope, and `messages/1` gives what
  the model reads of a batch.

  ## Governance

  Before a callback runs, an unchecked call is handed to the scope's
  `Tars.Hook`s. Three things can happen, and only the first reaches the tool:

    * allowed - the callback runs.
    * denied - the callback never runs and the model is told why, as an
      ordinary tool result. A refusal is an answer, so the turn carries on.
    * asked - the call **parks**. Nothing runs, nothing is appended to the
      conversation, and the batch reports it so the turn can stop and wait for
      a person. See `Tars.Agent.resume/2`.

  An approved call runs without the hooks being asked again.

  ## Recording what ran

  A scope with a `Tars.Ledger` has every allowed call claimed before its
  callback runs and settled with what it returned, under `Tars.Ledger.key/2`.
  A call already settled is answered with what it returned then, without
  running, and reported as `{:tool_replayed, call_id, name, result}`. A call
  claimed and never settled may or may not have had its effect, so it waits on
  `:ledger`, asking a person whether to run it again, and runs once they
  approve that, or at once, under the same key, where its tool declares it may
  run again (see `c:Tars.Tool.in_doubt/1`). Approving a call a hook asked
  about runs nothing the ledger holds as begun, and refusing one tells the
  model what the ledger holds, not that it never ran. A call whose claim the
  ledger cannot answer does not run. A tool that stops to ask before doing
  anything waits on `:tool`, and releases its claim.

  ## Stopping one call

  Every call in flight is registered under its agent and call id, so a single
  runaway tool can be stopped without touching the turn around it:

      Tars.LLM.ToolRunner.kill_call("acme/jon/assistant", "call_abc")

  The killed call is answered with an error result the same way a crash is, so
  the model is never left with an unanswered call. `in_flight/1` lists what
  could be stopped.
  """
  require Logger

  alias ReqLLM.Context
  alias Tars.Call
  alias Tars.Call.Tool
  alias Tars.Event
  alias Tars.Hook
  alias Tars.Ledger
  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Tool.Result

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
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: @registry)

  @doc """
  Runs every call at once and reports what each one did, in call order.

  Returns one `Tars.Call` per call. Use `messages/1` when nothing can park,
  and `parked/1` to find the calls waiting on a person.
  """
  @spec execute_many_async([Call.t() | Tars.Tool.call()], Scope.t()) :: [Call.t()]
  def execute_many_async(tool_calls, %Scope{} = scope) do
    turn = self()
    calls = Enum.map(tool_calls, &token/1)

    Tars.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      Enum.map(calls, &{&1, Scope.open(scope, Call.name(&1))}),
      fn {call, span} ->
        Tars.Tether.to(turn)
        in_span(call, span)
      end,
      ordered: true,
      max_concurrency: @max_concurrency,
      timeout: timeout(calls, scope),
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
  @spec messages([Call.t()]) :: [ReqLLM.Message.t()]
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

  @doc "The calls in a batch waiting on a person, each with the prompt a person is shown."
  @spec parked([Call.t()]) :: [{Tars.Tool.call(), String.t()}]
  def parked(calls) when is_list(calls) do
    for %Call{state: :waiting} = call <- calls, do: {Call.to_map(call), Call.prompt(call)}
  end

  @doc """
  The longest any of `tool_calls` may take.

  The longest timeout any of them declares, never more than the scope has left.
  """
  @spec timeout([Call.t() | Tars.Tool.call()], Scope.t()) :: timeout()
  def timeout(tool_calls, %Scope{config: config} = scope) do
    tool_calls
    |> Enum.map(&(Config.tool_timeout(config, tool_name(&1)) || @tool_timeout))
    |> Enum.max(fn -> @tool_timeout end)
    |> within(Scope.remaining_ms(scope))
  end

  # A batch admitted with nothing left still gets a moment to answer, so a call
  # that lands exactly on the deadline reports a result rather than a crash.
  defp within(declared, :infinity), do: declared
  defp within(declared, remaining), do: declared |> min(remaining) |> max(1)

  defp tool_name(%Call{} = call), do: Call.name(call)
  defp tool_name(%{name: name}), do: name

  @doc """
  Runs one call and reports what it did.

  An unchecked call is handed to the scope's hooks first. An approved one is
  not, since the decision has been made and asking again would park it
  forever, and one approved after the ledger asked about it runs again.
  """
  @spec execute(Call.t() | Tars.Tool.call(), Scope.t()) :: Call.t()
  def execute(call, %Scope{} = scope) do
    call = token(call)
    in_span(call, Scope.open(scope, Call.name(call)))
  end

  @doc """
  Answers a call a person refused, without running it.

  What `Tars.LLM.Turn.resume/3` uses for a denied call, so a refusal made by a
  person reaches the model in the same shape as one made by a hook.

  A call the ledger holds is not one that never ran. A settled one is answered
  with what it returned, as a replay is, and one claimed and never settled is
  refused with the model told it may already have done what it does.
  """
  @spec refuse(Call.t() | Tars.Tool.call(), Scope.t(), String.t()) :: Call.t()
  def refuse(call, %Scope{} = scope, reason) when is_binary(reason) do
    call = call |> token() |> Call.refuse(reason)
    span = Scope.open(scope, Call.name(call))
    result = refused(call, span, reason)
    Scope.close(span, outcome(result))
    settle({call, result})
  end

  defp refused(call, %Scope{ledger: nil} = scope, reason), do: deny(call, scope, reason)

  defp refused(call, %Scope{ledger: ledger} = scope, reason) do
    case Ledger.fetch(ledger, Ledger.key(scope, Call.to_map(call))) do
      {:ok, %Ledger.Entry{result: nil}} -> deny(call, scope, not_run_again(call, reason))
      {:ok, %Ledger.Entry{result: result}} -> replayed(call, scope, result)
      :error -> deny(call, scope, reason)
    end
  end

  defp not_run_again(call, reason) do
    name = Call.name(call)

    "#{name} was not run again, but it began before this agent was interrupted " <>
      "and may already have done what it does. #{reason}"
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

  defp token(%Call{} = call), do: call
  defp token(%{id: _, name: _, arguments: _} = call), do: Call.tool(call)

  defp in_span(call, span) do
    span
    |> Scope.closing(&run(call, &1), fn {_call, result} -> outcome(result) end)
    |> settle()
  end

  # A tool that reports its own failure answers the model successfully and the
  # span unsuccessfully: the model gets to correct itself, and a surface gets
  # to say the call did not do its job.
  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome({:waiting, _call}), do: {:error, :parked}

  defp outcome({:ok, %{"error" => error}} = result) do
    if Result.ok?(result), do: :ok, else: {:error, error}
  end

  defp outcome(_result), do: :ok

  defp settle({_call, {:waiting, %Call{} = waiting}}), do: Call.under(waiting, nil)
  defp settle({call, {:ok, _output} = result}), do: done(call, result)
  defp settle({call, {:error, _reason} = result}), do: done(call, result)

  # A tool that answers with none of those is a bug in the tool, and the model
  # is told so rather than the call crashing around it.
  defp settle({call, other}), do: done(call, {:error, "Tool answered with #{inspect(other)}"})

  defp done(call, result), do: call |> Call.under(nil) |> Call.answer(result)

  defp run(call, scope) do
    :ok = Tars.Scope.Context.put(scope, Call.to_map(call))
    register(scope, call)

    try do
      case checked(call, scope) do
        %Call{state: :denied, denied: denied} = refused ->
          {refused, deny(call, scope, denied.reason)}

        %Call{state: :waiting} = waiting ->
          {waiting, park(waiting, scope)}

        going ->
          {going, recorded(going, scope)}
      end
    after
      Registry.unregister(@registry, {scope.source.agent_id, call.id})
    end
  end

  defp checked(%Call{state: :unchecked} = call, scope),
    do: call |> Call.under(scope) |> Hook.check()

  defp checked(%Call{state: :approved} = call, scope), do: Call.under(call, scope)

  # A call is claimed before it runs, so a replay knows it began, and settled
  # after, so a replay knows what it returned.
  defp recorded(call, %Scope{ledger: nil} = scope), do: invoke(call, scope)

  defp recorded(call, %Scope{ledger: ledger} = scope) do
    key = Ledger.key(scope, Call.to_map(call))

    case Ledger.claim(ledger, key, Call.to_map(call)) do
      :ok ->
        run_claimed(call, scope, ledger, key)

      {:settled, result} ->
        replayed(call, scope, result)

      {:pending, _entry} ->
        if rerun?(call) or Config.tool_in_doubt(scope.config, Call.name(call)) == :rerun,
          do: run_claimed(call, scope, ledger, key),
          else: pending(call, scope)

      {:error, reason} ->
        deny(
          call,
          scope,
          "Tars could not record this call before running it, so it did not run: #{inspect(reason)}"
        )
    end
  end

  # A person approved running again a call the ledger held as begun.
  defp rerun?(%Call{state: state} = call),
    do: state == :approved and Call.asked_by?(call, :ledger)

  # A tool may ask to park, which ReqLLM's spec for its answer does not allow
  # for; see `answered/3`.
  @dialyzer {:nowarn_function, run_claimed: 4}

  defp run_claimed(call, scope, ledger, key) do
    case invoke(call, scope) do
      {:waiting, _call} = waiting ->
        _ = Ledger.release(ledger, key)
        waiting

      result ->
        with {:error, reason} <- Ledger.settle(ledger, key, result) do
          Logger.warning(
            "#{Call.name(call)} ran, but what it returned was not recorded: #{inspect(reason)}"
          )
        end

        result
    end
  end

  defp replayed(%Call{id: id} = call, scope, result) do
    name = Call.name(call)
    Event.emit(scope.source, {:tool_replayed, id, name, result})
    result
  end

  defp pending(call, scope), do: call |> Call.wait(:ledger, pending_prompt(call)) |> park(scope)

  defp pending_prompt(%Call{target: %Tool{name: name}}) do
    "#{name} began before this agent was interrupted, and may already have done what it does. " <>
      "Approve to run it again, or deny to tell the agent it may have run."
  end

  # Registration is best-effort bookkeeping for an operator, so a duplicate id
  # from a provider must not fail the call it belongs to.
  defp register(scope, call) do
    meta = %{name: Call.name(call), started_at: System.monotonic_time()}
    Registry.register(@registry, {scope.source.agent_id, call.id}, meta)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp invoke(%Call{id: id, target: %Tool{name: name, arguments: args}} = call, scope) do
    Event.emit(
      scope.source,
      {:tool_started, id, name, args, Ledger.idempotency_key(scope, Call.to_map(call))}
    )

    case Enum.find(Config.tools(scope.config), &(&1.name == name)) do
      nil -> finished(call, scope, {:error, "Unknown tool: #{name}"})
      tool -> tool |> answer(args) |> answered(call, scope)
    end
  end

  # ReqLLM's spec for a callback's answer is narrower than what a callback may
  # actually return, and a tool of ours may also ask to park.
  @dialyzer {:nowarn_function, answered: 3}

  defp answer(tool, arguments), do: ReqLLM.Tool.execute(tool, arguments)

  # A tool asking to park has not answered the model, so it is reported as a
  # pause rather than as a result.
  defp answered({:park, prompt}, call, scope) when is_binary(prompt),
    do: call |> Call.wait(:tool, prompt) |> park(scope)

  defp answered(result, call, scope), do: finished(call, scope, result)

  defp finished(%Call{id: id, target: %Tool{name: name}}, scope, result) do
    Event.emit(scope.source, {:tool_finished, id, name, result})

    result
  end

  defp deny(%Call{id: id, target: %Tool{name: name}}, scope, reason) do
    Event.emit(scope.source, {:tool_denied, id, name, reason})
    Result.error(:denied, reason)
  end

  defp park(%Call{id: id, target: %Tool{name: name}} = call, scope) do
    Event.emit(scope.source, {:tool_parked, id, name, Call.prompt(call)})
    {:waiting, call}
  end

  defp result_message(%Call{id: id, target: %Tool{name: name}}, output),
    do: Context.tool_result_message(name, id, output)

  defp reap(call, span, reason) do
    Scope.close(span, {:error, reason})
    done(call, {:error, "Tool crashed: #{inspect(reason)}"})
  end

  defp error_message(%Call{id: id, target: %Tool{name: name}}, reason) when is_binary(reason) do
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
