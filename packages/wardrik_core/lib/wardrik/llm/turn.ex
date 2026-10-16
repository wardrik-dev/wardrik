defmodule Wardrik.LLM.Turn do
  @moduledoc """
  One agent turn: streams a model response, runs any tool calls it asks for,
  and loops until the model produces a final answer.

  A turn is a token, the way a `Plug.Conn` is. `new/2` builds one from a
  scope and the conversation as it stands, `run/1` takes it and hands it
  back, and it is the same value whether it is running, waiting on a person,
  or done:

      turn = scope |> Wardrik.LLM.Turn.new(context) |> Wardrik.LLM.Turn.run()

      case turn do
        %Wardrik.LLM.Turn{state: :done, messages: messages} -> append(messages)
        %Wardrik.LLM.Turn{state: :waiting} -> hold(turn)
        %Wardrik.LLM.Turn{state: :failed, error: reason} -> report(reason)
      end

  `:messages` is what the turn added, a delta rather than a snapshot, so the
  caller remains the single writer of context. Stream and tool progress go out
  through the scope's event source, which means a turn needs no subscriber pid
  and does not care how many listeners there are.

  ## Fields

    * `:scope` - the `Wardrik.Scope` it runs under, `nil` while it is written down
    * `:context` - the conversation as it stands, what it added included
    * `:messages` - what it added, in order
    * `:remaining` - how many rounds of tool use it has left
    * `:response` - the model response whose tool calls it is running, if any
    * `:calls` - the `Wardrik.Call`s of that batch, or the model call it waits on
    * `:revision` - the `Wardrik.Hook.revision/1` of the hooks it parked under
    * `:preamble` - what the config's tools told the model as the turn began,
      put after the system prompt of every request it makes
    * `:labels` - what it has read, as `Wardrik.Label`s, which every batch
      after it is told
    * `:state` - `:running`, `:waiting`, `:done` or `:failed`
    * `:error` - why a failed turn failed

  ## Where a model call actually goes

  Every request is a `Wardrik.Call` through `Wardrik.Call.Pipeline`, as every
  tool call is: the scope's hooks decide it, and its `Wardrik.LLM.Dispatch`
  can route it, supply the key it runs under, or refuse it, and can book what
  it cost when it returns. Without a dispatch the request is made exactly as
  configured.

  ## Stopping early

  Three things stop a turn, and none of them lose what it has already produced:

    * `:yield` is read at an iteration boundary. The current model response and
      any tools it asked for run to completion; the turn returns rather than
      asking again.

    * `:interrupt` is read at a boundary *and* on every stream chunk, so it
      also stops a response that is still arriving. Whatever text had streamed
      is added as the assistant's message, verbatim.

    * an expired deadline on the scope stops the turn at a boundary, the way
      `:yield` does. It takes effect without a closing request, because
      spending more time is the one thing a deadline forbids.

  Neither message can land between a tool call and its result. A tool already
  running is not stopped — the mailbox is not read again until it returns — so
  a caller that must guarantee a stop needs to kill the process as well, or
  stop the one call with `Wardrik.LLM.ToolRunner.kill_call/2`.

  ## Stopping to ask

  A `Wardrik.Hook` that asks a person about a tool call parks the call. The
  turn comes back `:waiting` with nothing appended to the conversation, its
  batch in `:calls`, and `resume/2` finishes it once a person has decided.

  A hook that asks about a model call parks the turn before the call the same
  way, with the one call it waits on the model call itself, named `model`, so
  a person answers it the way they answer any other. Approving it makes the
  call; denying it fails the turn as `{:policy_denied, reason}`.

  A turn that waits is written down with no scope, so it holds no
  credentials and runs no processes, and `under/2` gives it the scope it
  resumes under.

  ## What the tools say first

  `new/2` asks each of the config's tools what it tells the model before the
  turn (see `c:Wardrik.Tool.context/1`), once, and every request the turn
  makes carries it after the system prompt. The turn keeps it, so a turn
  carried on after a lost node says what it began with. The labels of what a
  tool tells it are the turn's from the start.

  ## What the turn has read

  Once a call the turn made answers with something labelled (see
  `Wardrik.Call.label/2`), the turn carries the labels, and every batch after
  it runs under a scope that says so, for its hooks to weigh:
  `WardrikPolicy` holds a gated tool's call for a person after content from
  outside, since what the turn read may be what asked for it. A turn written
  down carries its labels, so one carried on after a lost node carries them
  still.

  What the turn read stays in the history it leaves, so a turn begun under a
  scope that carries labels already, as `Wardrik.Agent` begins one on a
  history that holds labelled content, carries them from the start.

  ## Surviving a lost node

  A scope with a journal, as `Wardrik.Agent` gives each turn it runs, is handed
  the turn, written down, before every batch of tool calls, and the batch runs
  only once the journal has answered `:ok`. A journal that does not answer
  ends the turn before anything runs. `replay/1` carries such a turn on, with
  the response it had, so the calls it asked for keep their ids and a
  `Wardrik.Ledger` can say which already ran.

  ## A model call that fails

  A call that fails is handed to the scope's `Wardrik.LLM.Retry`, with the
  failed try added to the request's attempts, which decides whether to ask
  again and after how long: by default after each wait the config's
  `:retries` lists, for a reason `Wardrik.Failure` calls transient, such as a
  stream that times out, before its first chunk or part way through. Each try
  goes through the hooks and the dispatch, which may send it to another
  model, and is its own `Wardrik.Event.ModelStarted` and
  `Wardrik.Event.ModelFinished`. A retry answers under the message id of the
  first try with the try's number added, `.2` for the second, so what a failed
  try had streamed is never taken for its answer. A call the retry lets go
  fails the turn. `:interrupt` stops the wait, and a turn past its deadline
  fails with the call's reason rather than waiting.

  ## The iteration cap

  `max_iterations` on the config bounds the rounds of tool use. When the last
  round has run, the turn makes one more request with no tools and a closing
  note added to the system prompt, so it ends with an answer drawn from what
  it found rather than with a tool exchange nobody read.
  """
  require Logger

  alias ReqLLM.Context
  alias Wardrik.Call
  alias Wardrik.Call.Pipeline
  alias Wardrik.Event
  alias Wardrik.Hook
  alias Wardrik.LLM.Attempt
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Retry
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias Wardrik.Tool
  alias Wardrik.Trace

  @enforce_keys [:context]
  defstruct [
    :scope,
    :context,
    :response,
    :revision,
    :error,
    :preamble,
    messages: [],
    remaining: :infinity,
    calls: [],
    state: :running,
    labels: []
  ]

  @type state() :: :running | :waiting | :done | :failed

  @type t() :: %__MODULE__{
          scope: Scope.t() | nil,
          context: Context.t(),
          response: ReqLLM.Response.t() | nil,
          revision: String.t() | nil,
          error: term(),
          preamble: String.t() | nil,
          messages: [ReqLLM.Message.t()],
          remaining: non_neg_integer() | :infinity,
          calls: [Call.t()],
          state: state(),
          labels: [Wardrik.Label.t()]
        }

  @typedoc "What a person decides about one call a turn waits on."
  @type decision() :: Pipeline.decision()

  @streamed :wardrik_streamed_text
  @answered :wardrik_answered

  @closing "You have used every tool call available for this turn. Answer now from what you have, and say plainly what you could not verify."

  @doc """
  A turn to answer `context` under `scope`, with the rounds its config allows,
  and what its tools tell the model first.
  """
  @spec new(Scope.t(), Context.t()) :: t()
  def new(%Scope{config: config} = scope, %Context{} = context) do
    {preamble, labels} = Tool.context(config.tools, scope)

    %__MODULE__{
      scope: scope,
      context: context,
      remaining: config.max_iterations,
      preamble: preamble,
      labels: Wardrik.Label.union(scope.labels, labels)
    }
  end

  @doc "Runs `turn` until it is done, waits on a person, or fails."
  @spec run(t()) :: t()
  def run(%__MODULE__{state: :running, scope: %Scope{}} = turn), do: loop(turn)

  @doc "The turn under `scope`, or under none for one that is written down."
  @spec under(t(), Scope.t() | nil) :: t()
  def under(%__MODULE__{} = turn, scope), do: %{turn | scope: scope}

  @doc "The turn done, having added `messages` besides what it already had."
  @spec done(t(), [ReqLLM.Message.t()]) :: t()
  def done(%__MODULE__{} = turn, messages \\ []),
    do: %{turn | state: :done, messages: turn.messages ++ messages}

  @doc "The turn failed, for `reason`."
  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = turn, reason), do: %{turn | state: :failed, error: reason}

  @doc """
  The calls the turn waits on, each with the prompt a person is shown, and
  with `:labels` where the turn has read something labelled, which may be
  what asked for it.
  """
  @spec waiting(t()) :: [{Wardrik.Tool.call(), String.t()}]
  def waiting(%__MODULE__{calls: calls, labels: []}), do: ToolRunner.parked(calls)

  def waiting(%__MODULE__{calls: calls, labels: labels}),
    do:
      for(
        {call, prompt} <- ToolRunner.parked(calls),
        do: {Map.put(call, :labels, labels), prompt}
      )

  @doc """
  The ids of the calls the turn waits on that were parked to resolve `ref`
  for `owner`; see `Wardrik.Credential.available/3`.
  """
  @spec awaiting(t(), Wardrik.Credential.ref(), Wardrik.Credential.owner()) :: [String.t()]
  def awaiting(%__MODULE__{calls: calls}, ref, owner),
    do: for(call <- calls, Call.awaits?(call, ref, owner), do: call.id)

  @doc "The ids of the tool calls the turn's response asked for."
  @spec call_ids(t()) :: [String.t()]
  def call_ids(%__MODULE__{response: nil}), do: []

  def call_ids(%__MODULE__{response: response}) do
    %{tool_calls: calls} = ReqLLM.Response.classify(response)
    Enum.map(calls, & &1.id)
  end

  @doc "Whether the turn waits on a person before a model call rather than at a tool call."
  @spec model?(t()) :: boolean()
  def model?(%__MODULE__{state: :waiting, response: nil}), do: true
  def model?(%__MODULE__{}), do: false

  @doc """
  Finishes a waiting turn, applying one decision per waiting call.

  Approved calls go ahead now, without the hooks being asked again: the
  decision has been made, and asking again would park them forever. Each hook
  that asked hears of the approval through `Wardrik.Hook.approved/1`. A call that
  parked because it may already have run runs again once approved; one
  approved when a hook asked, and found by the ledger to have begun since,
  parks again to ask that. Denied calls are answered with the reason, which
  the model reads and can act on. A call with no decision stays waiting, so a
  person can answer them one at a time.

  A turn that parked under hooks other than its scope's, by
  `Wardrik.Hook.revision/1`, has the scope's hooks asked about every call a hook
  was waiting on before any decision is applied, and a decision about such a
  call is set aside: the call goes ahead, is refused, or waits again on what
  the hooks ask now. A call waiting on its tool or the ledger keeps its
  decision.
  """
  @spec resume(t(), %{String.t() => decision()}) :: t()
  def resume(%__MODULE__{state: :waiting, response: nil, calls: [call]} = turn, decisions)
      when is_map(decisions) do
    case if(stale?(turn), do: :redecide, else: Map.get(decisions, call.id)) do
      nil ->
        turn

      :redecide ->
        turn |> running() |> loop()

      decision ->
        case call |> Call.under(turn.scope) |> Pipeline.answer(decision) do
          %Call{state: :approved} = approved -> turn |> running() |> loop(approved: approved)
          %Call{denied: denied} -> fail(turn, {:policy_denied, denied.reason})
        end
    end
  end

  def resume(%__MODULE__{state: :waiting} = turn, decisions) when is_map(decisions) do
    stale? = stale?(turn)
    calls = Enum.map(turn.calls, &decide(&1, decisions, batch(turn), stale?))
    resumed = read(%{turn | calls: calls}, calls)

    if Enum.any?(resumed.calls, &Call.waiting?/1),
      do: %{resumed | revision: revision(turn.scope)},
      else: finish(%{resumed | state: :running, revision: nil})
  end

  defp running(turn), do: %{turn | state: :running, calls: [], revision: nil}

  defp stale?(%__MODULE__{revision: revision, scope: scope}), do: revision != revision(scope)

  defp revision(%Scope{hooks: hooks}), do: Hook.revision(hooks)

  defp decide(%Call{state: :waiting} = call, decisions, scope, stale?) do
    if stale? and Call.asked_by_hook?(call),
      do: call |> Call.reset() |> ToolRunner.execute(scope),
      else: decided(call, Map.get(decisions, call.id), scope)
  end

  defp decide(%Call{} = call, _decisions, _scope, _stale?), do: call

  defp decided(call, nil, _scope), do: call

  defp decided(call, decision, scope),
    do: call |> Call.under(scope) |> Pipeline.answer(decision) |> ToolRunner.execute(scope)

  # A batch every call of which has been answered is appended, and the turn
  # goes on.
  defp finish(%__MODULE__{calls: calls} = turn) do
    case append_tool_exchange(turn.context, turn.response, ToolRunner.messages(calls)) do
      {:cont, context, appended} -> continue(turn, context, appended)
      {:error, reason} -> fail(turn, reason)
    end
  end

  @doc """
  Carries on a turn the journal was handed before a batch: the batch runs,
  with the ledger answering for any call that already had, and the turn goes
  on from there.
  """
  @spec replay(t()) :: t()
  def replay(%__MODULE__{state: :running, scope: %Scope{}, response: %ReqLLM.Response{}} = turn),
    do: advance(turn)

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

  # `opts` apply to the next model call alone.
  defp loop(%__MODULE__{scope: scope} = turn, opts \\ []) do
    cond do
      Scope.expired?(scope) -> out_of_time(turn)
      turn.remaining == 0 -> wrap_up(turn, opts)
      true -> iterate(turn, opts)
    end
  end

  defp out_of_time(turn) do
    Logger.warning("Turn reached its deadline, stopping with what it has")
    Event.emit(turn.scope.source, %Event.DeadlineReached{message_count: length(turn.messages)})
    done(turn)
  end

  defp iterate(turn, opts) do
    case request(turn, turn.scope, opts) do
      {:ok, response} ->
        advance(%{turn | response: response})

      {:park, waiting} ->
        waiting_on_model(turn, waiting)

      {:interrupted, text} ->
        done(turn, partial(text))

      {:error, reason} ->
        Logger.warning("Error streaming text: #{inspect(reason)}")
        fail(turn, reason)
    end
  end

  defp partial(""), do: []
  defp partial(text), do: [Context.assistant(text)]

  # One last request without tools. Any tool call the model asks for anyway
  # is dropped, so the conversation never ends on an unanswered call.
  defp wrap_up(%__MODULE__{scope: scope} = turn, opts) do
    Logger.warning("Turn hit its iteration cap, answering without tools")

    case request(turn, %{scope | config: %{scope.config | tools: []}}, opts, true) do
      {:ok, response} ->
        %{text: text} = ReqLLM.Response.classify(response)
        done(turn, partial(text))

      {:park, waiting} ->
        waiting_on_model(turn, waiting)

      {:interrupted, text} ->
        done(turn, partial(text))

      {:error, reason} ->
        Logger.warning("Error streaming text: #{inspect(reason)}")
        fail(turn, reason)
    end
  end

  defp waiting_on_model(turn, waiting) do
    %{
      turn
      | state: :waiting,
        response: nil,
        calls: [Call.under(waiting, nil)],
        revision: revision(turn.scope)
    }
  end

  # A request's system prompt: the config's, what the tools said as the turn
  # began, and the closing note on the last request of a turn at its cap. A
  # turn written down before it had a preamble has none.
  defp system(system, turn, closing?) do
    case Enum.reject(
           [system, Map.get(turn, :preamble), closing? && @closing],
           &(&1 in [nil, false, ""])
         ) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp advance(turn) do
    case journal(turn) do
      :ok -> handle(turn)
      {:error, reason} -> fail(turn, reason)
    end
  end

  # A batch of tool calls is handed to the journal, as the turn written down,
  # before any of it runs. A final answer changes nothing the journal needs,
  # and is not.
  defp journal(%__MODULE__{scope: %Scope{journal: nil}}), do: :ok

  defp journal(%__MODULE__{scope: %Scope{journal: journal}, response: response} = turn) do
    case ReqLLM.Response.classify(response) do
      %{type: :tool_calls} ->
        case GenServer.call(journal, {:checkpoint, under(turn, nil)}, :timer.seconds(30)) do
          :ok -> :ok
          {:error, reason} -> {:error, {:checkpoint_failed, reason}}
        end

      _answer ->
        :ok
    end
  catch
    :exit, reason -> {:error, {:checkpoint_failed, reason}}
  end

  # The turn reports that it waits; the agent holding it is what announces the
  # state change, because only it can say that `resume/2` will now work.
  defp handle(turn) do
    case handle_response(batch(turn), turn.context, turn.response) do
      {:done, messages} ->
        done(turn, messages)

      {:cont, context, messages, calls} ->
        turn |> read(calls) |> continue(context, messages)

      {:waiting, calls} ->
        %{read(turn, calls) | state: :waiting, calls: calls, revision: revision(turn.scope)}

      {:error, reason} ->
        fail(turn, reason)
    end
  end

  # The scope a batch runs under: the turn's, for this round, carrying what
  # the turn has read.
  defp batch(turn), do: %{Scope.batch(turn.scope, rounds(turn)) | labels: turn.labels}

  # The turn, carrying what `calls` answered with.
  defp read(%__MODULE__{} = turn, calls),
    do: %{turn | labels: Enum.reduce(calls, turn.labels, &Wardrik.Label.union(&2, &1.labels))}

  defp continue(turn, context, messages) do
    turn = %{
      turn
      | context: context,
        response: nil,
        calls: [],
        messages: turn.messages ++ messages
    }

    if stop_requested?(),
      do: done(turn),
      else: loop(%{turn | remaining: countdown(turn.remaining)})
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

  # Each round of tool use adds one assistant message to what the turn has
  # produced, so their count is the round a batch belongs to.
  defp rounds(%__MODULE__{messages: messages}), do: Enum.count(messages, &(&1.role == :assistant))

  # The message a model call answers with is named by where the turn is: its
  # span and its round, so a turn replayed names it as it did the first time.
  defp message_id(%__MODULE__{scope: %Scope{source: source}} = turn),
    do: "#{source.trace.span_id}.m#{rounds(turn)}"

  # A call a hook parks is never made, so it has no model events. `opts` hold
  # the call a person approved, which every try goes ahead as. `scope` is the
  # turn's, or one whose config is narrowed for the last request of a turn at
  # its cap.
  defp request(%__MODULE__{} = turn, %Scope{config: config} = scope, opts, closing? \\ false) do
    config = %{config | system: system(config.system, turn, closing?)}
    asked(%{scope | config: config}, Request.new(config, turn.context), message_id(turn), opts)
  end

  defp asked(%Scope{} = scope, %Request{} = request, message_id, opts) do
    case request |> Pipeline.model(scope, opts[:approved]) |> Pipeline.decide() do
      %Call{state: :waiting} = waiting ->
        {:park, waiting}

      %Call{state: :denied, denied: denied} ->
        {:error, {:policy_denied, denied.reason}}

      call ->
        call
        |> make(tried_id(message_id, request))
        |> again(scope, request, message_id, opts)
    end
  end

  defp tried_id(message_id, %Request{attempts: []}), do: message_id
  defp tried_id(message_id, %Request{attempts: tried}), do: "#{message_id}.#{length(tried) + 1}"

  defp again({{:error, reason} = failed, model_spec}, scope, request, message_id, opts) do
    attempt = %Attempt{model_spec: model_spec, reason: reason, answered?: Process.get(@answered)}
    tried = Request.failed(request, attempt)

    case if(Scope.expired?(scope), do: :stop, else: Retry.again(scope, tried)) do
      {:again, wait} ->
        Logger.warning("Model call failed, asking again in #{wait}ms: #{inspect(reason)}")

        receive do
          :interrupt -> {:interrupted, ""}
        after
          wait -> asked(scope, tried, message_id, opts)
        end

      :stop ->
        failed
    end
  end

  defp again({result, _model_spec}, _scope, _request, _message_id, _opts), do: result

  # What a try came to, with the model it went to once the dispatch had
  # admitted it.
  defp make(%Call{scope: %Scope{source: source}} = call, message_id) do
    started_at = System.monotonic_time()

    Event.emit(
      source,
      %Event.ModelStarted{
        message_id: message_id,
        model_spec: call.target.model_spec,
        decided_by: Call.decided_by(call)
      }
    )

    Process.put(@streamed, [])
    Process.put(@answered, false)

    made = Pipeline.run(call, &streamed/1)
    result = unsettled(made)

    Event.emit(
      source,
      %Event.ModelFinished{
        message_id: message_id,
        outcome: outcome(result),
        duration_ms: Trace.elapsed_ms(started_at),
        response: answer(result),
        cost: made.cost
      }
    )

    {result, made.target.model_spec}
  end

  defp streamed(%Call{scope: scope} = call),
    do: Call.answer(call, call |> Pipeline.request() |> stream(scope) |> settled())

  defp unsettled(%Call{result: {:error, reason, _text}}), do: {:error, reason}
  defp unsettled(%Call{result: result}), do: result

  # What the model answered, without the conversation it was answering, which
  # every subscriber already has.
  defp answer({:ok, %ReqLLM.Response{} = response}), do: %{response | context: nil, stream: nil}
  defp answer(_failed), do: nil

  # A stream that failed once the provider had begun to answer settles with
  # the text that had streamed.
  defp settled({:error, reason}) do
    if Process.get(@answered), do: {:error, reason, streamed_text()}, else: {:error, reason}
  end

  defp settled(result), do: result

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

    if ToolRunner.parked(outcomes) != [] do
      {:waiting, outcomes}
    else
      with {:cont, context, messages} <-
             append_tool_exchange(context, response, ToolRunner.messages(outcomes)),
           do: {:cont, context, messages, outcomes}
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
        Process.put(@answered, true)
        Event.emit(source, %Event.Chunk{chunk: chunk})
        if interrupted?(), do: throw(:interrupt)
      end,
      on_meta: &Event.emit(source, %Event.Meta{chunk: &1}),
      on_result: fn text ->
        Process.put(@streamed, [text | Process.get(@streamed, [])])
        Event.emit(source, %Event.Result{text: text})
      end,
      on_thinking: &Event.emit(source, %Event.Thinking{text: &1}),
      on_tool_call: &Event.emit(source, %Event.ToolCall{call: &1})
    )
  end
end
