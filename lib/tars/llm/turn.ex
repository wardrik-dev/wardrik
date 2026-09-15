defmodule Tars.LLM.Turn do
  @moduledoc """
  Runs a single agent turn: streams a model response, executes any tool calls,
  and loops until the model produces a final answer.

  Returns the messages appended *during* this turn, a delta rather than a
  snapshot, so the caller remains the single writer of context. Stream and tool
  progress go out through the scope's event source, which means this module
  needs no subscriber pid and does not care how many listeners there are.

  Pure orchestration: it holds no state of its own, so tests can drive `run/2`
  directly after subscribing to the scope's agent id.

  ## Where a model call actually goes

  Every request passes through `Tars.LLM.Dispatch`, so a host can route it,
  supply the key it runs under, or refuse it, and can book what it cost when it
  returns. Without a dispatch the request is made exactly as configured.

  ## Stopping early

  Three things stop a turn, and none of them lose what it has already produced:

    * `:yield` is read at an iteration boundary. The current model response and
      any tools it asked for run to completion; the turn returns rather than
      asking again.

    * `:interrupt` is read at a boundary *and* on every stream chunk, so it
      also stops a response that is still arriving. Whatever text had streamed
      is returned as the assistant's message, verbatim.

    * an expired deadline on the scope stops the turn at a boundary, the way
      `:yield` does. It takes effect without a closing request, because
      spending more time is the one thing a deadline forbids.

  Neither message can land between a tool call and its result. A tool already
  running is not stopped — the mailbox is not read again until it returns — so
  a caller that must guarantee a stop needs to kill the process as well, or
  stop the one call with `Tars.LLM.ToolRunner.kill_call/2`.

  ## Stopping to ask

  A policy that answers `{:ask, prompt}` parks the call. The turn returns
  `{:parked, parked}` with nothing appended to the conversation, and
  `resume/3` finishes it once a person has decided. See
  `Tars.LLM.Turn.Parked`.

  ## The iteration cap

  `max_iterations` on the config bounds the rounds of tool use. When the last
  round has run, the turn makes one more request with no tools and a closing
  note added to the system prompt, so it ends with an answer drawn from what
  it found rather than with a tool exchange nobody read.
  """
  require Logger

  alias ReqLLM.Context
  alias Tars.Event
  alias Tars.LLM.Dispatch
  alias Tars.LLM.Request
  alias Tars.LLM.ToolRunner
  alias Tars.LLM.Turn.Parked
  alias Tars.Scope
  alias Tars.Trace

  @streamed :tars_streamed_text

  @closing "You have used every tool call available for this turn. Answer now from what you have, and say plainly what you could not verify."

  @typedoc "How a turn ended."
  @type result() ::
          {:ok, [ReqLLM.Message.t()]} | {:parked, Parked.t()} | {:error, term()}

  @spec run(Scope.t(), Context.t()) :: result()
  def run(%Scope{} = scope, %Context{} = context) do
    loop(scope, context, [], scope.config.max_iterations)
  end

  @doc """
  Finishes a turn that parked, applying one decision per waiting call.

  Approved calls run now, with the policy no longer consulted: the decision has
  been made, and asking again would park them forever. Denied calls are
  answered with the reason, which the model reads and can act on. A call with
  no decision stays parked, so a person can answer them one at a time.
  """
  @spec resume(Scope.t(), Parked.t(), %{String.t() => Parked.decision()}) :: result()
  def resume(%Scope{} = scope, %Parked{} = parked, decisions) when is_map(decisions) do
    resumed = %{parked | outcomes: Enum.map(parked.outcomes, &decide(&1, decisions, scope))}

    if Parked.waiting?(resumed), do: {:parked, resumed}, else: finish(scope, resumed)
  end

  defp decide({:settled, _call, _message} = outcome, _decisions, _scope), do: outcome

  defp decide({:parked, call, prompt} = outcome, decisions, scope) do
    case Map.get(decisions, call.id) do
      :approve -> ToolRunner.execute(call, scope, authorize: false)
      {:deny, reason} -> ToolRunner.refuse(call, scope, reason)
      nil -> outcome
      other -> ToolRunner.refuse(call, scope, "Undecidable answer #{inspect(other)}: #{prompt}")
    end
  end

  defp finish(scope, %Parked{} = parked) do
    messages = ToolRunner.messages(parked.outcomes)

    case append_tool_exchange(parked.context, parked.response, messages) do
      {:cont, context, appended} ->
        continue(scope, context, appended, parked.acc, parked.remaining)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Asks the process running a turn to stop iterating once it reaches a boundary."
  @spec yield(pid()) :: :ok
  def yield(pid) when is_pid(pid) do
    send(pid, :yield)
    :ok
  end

  @doc "Asks the process running a turn to stop as soon as it can, mid-response if need be."
  @spec interrupt(pid()) :: :ok
  def interrupt(pid) when is_pid(pid) do
    send(pid, :interrupt)
    :ok
  end

  # `acc` holds this turn's messages in reverse order.
  defp loop(scope, context, acc, remaining) do
    cond do
      Scope.expired?(scope) -> out_of_time(scope, acc)
      remaining == 0 -> wrap_up(scope, context, acc)
      true -> iterate(scope, context, acc, remaining)
    end
  end

  defp out_of_time(scope, acc) do
    Logger.warning("Turn reached its deadline, stopping with what it has")
    Event.emit(scope.source, {:deadline_reached, length(acc)})
    {:ok, Enum.reverse(acc)}
  end

  defp iterate(scope, context, acc, remaining) do
    case request(scope, context) do
      {:ok, response} ->
        advance(scope, context, acc, remaining, response)

      {:interrupted, text} ->
        {:ok, Enum.reverse(acc, partial(text))}

      {:error, reason} ->
        Logger.warning("Error streaming text: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp partial(""), do: []
  defp partial(text), do: [Context.assistant(text)]

  # One last request without tools. Any tool call the model asks for anyway
  # is dropped, so the conversation never ends on an unanswered call.
  defp wrap_up(scope, context, acc) do
    Logger.warning("Turn hit its iteration cap, answering without tools")
    config = %{scope.config | tools: [], system: closing(scope.config.system)}

    case request(%{scope | config: config}, context) do
      {:ok, response} ->
        %{text: text} = ReqLLM.Response.classify(response)
        {:ok, Enum.reverse(acc, partial(text))}

      {:interrupted, text} ->
        {:ok, Enum.reverse(acc, partial(text))}

      {:error, reason} ->
        Logger.warning("Error streaming text: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp closing(nil), do: @closing
  defp closing(system), do: system <> "\n\n" <> @closing

  defp advance(scope, context, acc, remaining, response) do
    case handle_response(scope, context, response) do
      {:done, messages} -> {:ok, Enum.reverse(acc, messages)}
      {:cont, context, messages} -> continue(scope, context, messages, acc, remaining)
      {:waiting, outcomes} -> park(context, response, outcomes, acc, remaining)
      {:error, reason} -> {:error, reason}
    end
  end

  # The turn reports that it stopped; the agent holding it is what announces
  # the state change, because only it can say that `resume/2` will now work.
  defp park(context, response, outcomes, acc, remaining) do
    {:parked, Parked.new(context, response, outcomes, acc, remaining)}
  end

  defp continue(scope, context, messages, acc, remaining) do
    acc = Enum.reverse(messages, acc)

    if stop_requested?(),
      do: {:ok, Enum.reverse(acc)},
      else: loop(scope, context, acc, countdown(remaining))
  end

  defp stop_requested? do
    receive do
      :yield -> true
      :interrupt -> true
    after
      0 -> false
    end
  end

  defp interrupted? do
    receive do
      :interrupt -> true
    after
      0 -> false
    end
  end

  defp countdown(:infinity), do: :infinity
  defp countdown(remaining), do: remaining - 1

  defp request(%Scope{source: source} = scope, context) do
    started_at = System.monotonic_time()
    request = Request.new(scope.config, context)
    Event.emit(source, {:model_started, request.model_spec})
    Process.put(@streamed, [])

    result =
      with {:ok, admitted} <- Dispatch.admit(scope, request) do
        admitted |> stream(scope) |> tap(&Dispatch.settle(scope, admitted, &1))
      end

    Event.emit(source, {:model_finished, outcome(result), Trace.elapsed_ms(started_at)})

    result
  end

  defp stream(%Request{} = request, %Scope{} = scope) do
    with {:ok, streamed} <- ReqLLM.stream_text(request.model_spec, request.context, request.opts) do
      process_stream(streamed, scope)
    end
  catch
    :interrupt -> {:interrupted, streamed_text()}
  end

  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome({:interrupted, _text}), do: {:error, :interrupted}
  defp outcome(_result), do: :ok

  defp streamed_text, do: @streamed |> Process.get([]) |> Enum.reverse() |> IO.iodata_to_binary()

  defp handle_response(scope, context, %ReqLLM.Response{} = response) do
    case ReqLLM.Response.classify(response) do
      %{type: :final_answer, text: text} ->
        {:done, [assistant_message(response, text)]}

      %{type: :tool_calls, tool_calls: tool_calls, text: text} ->
        case Enum.reject(tool_calls, &ReqLLM.ToolCall.flagged_builtin?/1) do
          [] -> {:done, [assistant_message(response, text)]}
          calls -> settle_calls(scope, context, response, calls)
        end
    end
  end

  defp settle_calls(scope, context, response, calls) do
    outcomes = ToolRunner.execute_many_async(calls, scope)

    if Enum.any?(outcomes, &match?({:parked, _call, _prompt}, &1)) do
      {:waiting, outcomes}
    else
      append_tool_exchange(context, response, ToolRunner.messages(outcomes))
    end
  end

  # `response.message` is the canonical assistant message; it carries thinking
  # blocks and tool calls that rebuilding from text alone would discard.
  defp assistant_message(%ReqLLM.Response{message: nil}, text), do: Context.assistant(text)
  defp assistant_message(%ReqLLM.Response{message: message}, _text), do: message

  defp append_tool_exchange(context, response, results) do
    before = length(context.messages)

    case Context.append_tool_exchange(context, response, results) do
      {:ok, context} ->
        {:cont, context, Enum.drop(context.messages, before)}

      {:error, reason} ->
        Logger.warning("Error appending tool exchange: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # The callbacks run in this process, so `:interrupt` is read from the same
  # mailbox the boundary reads. A throw escapes `process_stream/2`, which
  # catches only exits, leaving what streamed so far recoverable.
  defp process_stream(streamed, %Scope{source: source}) do
    streamed
    |> ReqLLM.StreamResponse.process_stream(
      on_chunk: fn chunk ->
        Event.emit(source, {:chunk, chunk})
        if interrupted?(), do: throw(:interrupt)
      end,
      on_meta: &Event.emit(source, {:meta, &1}),
      on_result: fn text ->
        Process.put(@streamed, [text | Process.get(@streamed, [])])
        Event.emit(source, {:result, text})
      end,
      on_thinking: &Event.emit(source, {:thinking, &1}),
      on_tool_call: &Event.emit(source, {:tool_call, &1})
    )
  end
end
