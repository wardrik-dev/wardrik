defmodule Tars.LLM.ToolRunner do
  @moduledoc """
  Executes model-requested tool calls, each isolated in its own supervised task.

  A tool crash, exit or hang is contained: it becomes an error tool-result
  rather than taking down the turn. The reverse does not hold: a turn that is
  killed takes the calls it has in flight with it. Every call is answered with exactly one
  canonical tool-result message, including calls whose task died, which is
  what `ReqLLM.Context.append_tool_exchange/3` requires.

  Each call runs under its own child span, so its events are attributed to
  that call rather than to the turn as a whole. A tool built with
  `Tars.Tool.new!/1` is handed the call under that scope, which is how a tool
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

  ## Steps

  Every call passes through the same steps, in order, as a `Plug.Conn`
  passes through a pipeline:

    1. the scope's hooks decide an unchecked call
    2. the ledger claims an allowed or approved call
    3. a refused call is answered with why
    4. the tool runs an allowed or approved call, or is handed it; see
       `Tars.Tool`
    5. the ledger records what a claimed call answered

  Each step acts on the calls in the states it is for and hands every other
  on as it came, so a call answered, refused or waiting on a person passes
  through the steps after it.

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
  @claim :tars_ledger_key

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

  What `Tars.LLM.Turn.resume/2` uses for a denied call, so a refusal made by a
  person reaches the model in the same shape as one made by a hook.

  A call the ledger holds is not one that never ran. A settled one is answered
  with what it returned, as a replay is, and one claimed and never settled is
  refused with the model told it may already have done what it does.
  """
  @spec refuse(Call.t() | Tars.Tool.call(), Scope.t(), String.t()) :: Call.t()
  def refuse(call, %Scope{} = scope, reason) when is_binary(reason) do
    call = token(call)
    span = Scope.open(scope, Call.name(call))

    call
    |> Call.refuse(reason)
    |> Call.under(span)
    |> held()
    |> refused()
    |> tap(&Scope.close(span, outcome(&1)))
    |> Call.under(nil)
  end

  # A refused call the ledger holds is not one that never ran.
  defp held(%Call{scope: %Scope{ledger: nil}} = call), do: call

  defp held(%Call{scope: %Scope{ledger: ledger} = scope, denied: denied} = call) do
    case Ledger.fetch(ledger, Ledger.key(scope, Call.to_map(call))) do
      {:ok, %Ledger.Entry{result: nil}} -> Call.refuse(call, not_run_again(call, denied.reason))
      {:ok, %Ledger.Entry{result: result}} -> replayed(call, result)
      :error -> call
    end
  end

  defp not_run_again(call, reason) do
    "#{Call.name(call)} was not run again, but it began before this agent was interrupted " <>
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
    |> Scope.closing(&run(call, &1), &outcome/1)
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

  # Each step acts on the calls in the states it is for and hands every other
  # on as it came, so a call answered, refused or waiting on a person passes
  # through the steps after.
  defp run(call, scope) do
    register(scope, call)

    try do
      call
      |> Call.under(scope)
      |> check()
      |> claim()
      |> refused()
      |> invoke()
      |> record()
    after
      Registry.unregister(@registry, {scope.source.agent_id, call.id})
    end
  end

  # The hooks decide an unchecked call. An approved one has been decided.
  defp check(%Call{state: :unchecked} = call), do: call |> Hook.check() |> announced()
  defp check(call), do: call

  # A call is claimed before it runs, so a replay knows it began, and settled
  # after, so a replay knows what it returned.
  defp claim(%Call{state: state, scope: %Scope{ledger: ledger} = scope} = call)
       when state in [:allowed, :approved] and ledger != nil do
    key = Ledger.key(scope, Call.to_map(call))

    case Ledger.claim(ledger, key, Call.to_map(call)) do
      :ok ->
        Call.put_private(call, @claim, key)

      {:settled, result} ->
        replayed(call, result)

      {:pending, _entry} ->
        if rerun?(call) or Config.tool_in_doubt(scope.config, Call.name(call)) == :rerun,
          do: Call.put_private(call, @claim, key),
          else: call |> Call.wait(:ledger, pending_prompt(call)) |> announced()

      {:error, reason} ->
        Call.refuse(
          call,
          :ledger,
          "Tars could not record this call before running it, so it did not run: #{inspect(reason)}"
        )
    end
  end

  defp claim(call), do: call

  # A person approved running again a call the ledger held as begun.
  defp rerun?(%Call{state: state} = call),
    do: state == :approved and Call.asked_by?(call, :ledger)

  defp pending_prompt(call) do
    "#{Call.name(call)} began before this agent was interrupted, and may already have done what it does. " <>
      "Approve to run it again, or deny to tell the agent it may have run."
  end

  # A refused call is answered with why, as an ordinary tool result.
  defp refused(%Call{state: :denied, denied: denied} = call) do
    emit(call, {:tool_denied, call.id, Call.name(call), denied.reason})
    Call.answer(call, Result.error(:denied, denied.reason))
  end

  defp refused(call), do: call

  defp invoke(%Call{state: state, target: %Tool{name: name, arguments: args}} = call)
       when state in [:allowed, :approved] do
    emit(call, {:tool_started, call.id, name, args, Ledger.idempotency_key(call)})

    case Enum.find(Config.tools(call.scope.config), &(&1.name == name)) do
      nil -> finished(call, {:error, "Unknown tool: #{name}"})
      %ReqLLM.Tool{callback: {Tars.Tool, :invoke, [handler]}} = tool -> hand(call, tool, handler)
      tool -> finished(call, ReqLLM.Tool.execute(tool, args))
    end
  end

  defp invoke(call), do: call

  # A tool built with `Tars.Tool.new!/1` is handed the call, and what it hands
  # back is read for its answer or its park, and nothing else.
  defp hand(%Call{target: target} = call, tool, handler) do
    case ReqLLM.Tool.validate_input(tool, target.arguments) do
      {:ok, input} ->
        handler |> Tars.Tool.hand(%{call | target: %{target | arguments: input}}) |> took(call)

      {:error, reason} ->
        finished(call, {:error, reason})
    end
  end

  defp took(%Call{state: :done, result: result}, call), do: finished(call, result)

  defp took(%Call{state: :waiting} = parked, call),
    do: call |> Call.park(Call.prompt(parked)) |> announced()

  defp took(other, call), do: finished(call, other)

  # A claimed call is settled with what it answered. One whose tool stopped to
  # ask before doing anything gives its claim back.
  defp record(%Call{private: %{@claim => key}} = call) when key != nil do
    %Call{scope: %Scope{ledger: ledger}} = call

    case call.state do
      :done -> settle(call, ledger, key)
      :waiting -> _ = Ledger.release(ledger, key)
    end

    Call.put_private(call, @claim, nil)
  end

  defp record(call), do: call

  defp settle(call, ledger, key) do
    with {:error, reason} <- Ledger.settle(ledger, key, call.result) do
      Logger.warning(
        "#{Call.name(call)} ran, but what it returned was not recorded: #{inspect(reason)}"
      )
    end
  end

  defp replayed(call, result) do
    emit(call, {:tool_replayed, call.id, Call.name(call), result})
    Call.answer(call, result)
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

  # A tool that answers with neither `{:ok, _}` nor `{:error, _}` is a bug in
  # the tool, and the model is told so rather than the call crashing around it.
  defp finished(call, result) do
    emit(call, {:tool_finished, call.id, Call.name(call), result})

    case result do
      {:ok, _output} -> Call.answer(call, result)
      {:error, _reason} -> Call.answer(call, result)
      other -> Call.answer(call, {:error, "Tool answered with #{inspect(other)}"})
    end
  end

  defp announced(%Call{state: :waiting} = call) do
    emit(call, {:tool_parked, call.id, Call.name(call), Call.prompt(call)})
    call
  end

  defp announced(call), do: call

  defp emit(%Call{scope: %Scope{source: source}}, payload), do: Event.emit(source, payload)

  defp result_message(%Call{id: id, target: %Tool{name: name}}, output),
    do: Context.tool_result_message(name, id, output)

  defp reap(call, span, reason) do
    Scope.close(span, {:error, reason})
    Call.answer(call, {:error, "Tool crashed: #{inspect(reason)}"})
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
