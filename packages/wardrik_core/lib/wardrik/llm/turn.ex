defmodule Wardrik.LLM.Turn do
  @moduledoc """
  One agent turn: streams a model's answer, runs any tool calls it asks for,
  and loops until the model produces a final answer.

  A turn is a token, the way a `Plug.Conn` is. `new/2` builds one from a
  run and the conversation as it stands, `run/1` takes it and hands it
  back, and it is the same value whether it is running, waiting on a person,
  or done. It is a `Wardrik.Turn`, which says how it came out:

      turn = run |> Wardrik.LLM.Turn.new(context) |> Wardrik.LLM.Turn.run()

      case Wardrik.Turn.status(turn) do
        {:done, messages, _labels} -> append(messages)
        :waiting -> hold(turn)
        {:failed, reason} -> report(reason)
      end

  `:messages` is what the turn added, a delta rather than a snapshot, so the
  caller remains the single writer of history. Stream and tool progress go out
  through the run's event source, which means a turn needs no subscriber pid
  and does not care how many listeners there are.

  ## Fields

    * `:run` - the `Wardrik.Run` it runs under, `nil` while it is written down
    * `:context` - the `Wardrik.Conversation` as it stands, what it added
      included, and `nil` where it is stored beside the history it began on,
      which with `:messages` makes it again; see `dump/1` and `load/2`
    * `:messages` - what it added, in order
    * `:remaining` - how many rounds of tool use it has left
    * `:answer` - the model's `Wardrik.LLM.Answer` whose tool calls it is
      running, if any
    * `:calls` - the `Wardrik.Call`s of that batch, or the model call it waits on
    * `:revision` - the `Wardrik.Hook.revision/1` of the hooks it parked under
    * `:preamble` - what the config's tools told the model as the turn began,
      put after the system prompt of every request it makes
    * `:labels` - what it has read, as `Wardrik.Label`s, which every batch
      after it is told
    * `:state` - `:running`, `{:waiting, :tools}` on calls of its batch,
      `{:waiting, :model}` on the model call it is about to make, `:done` or
      `:failed`
    * `:error` - why a failed turn failed

  ## Where a model call actually goes

  Every request is a `Wardrik.Call` through `Wardrik.Call.Pipeline`, as every
  tool call is: the run's hooks decide it, and its `Wardrik.LLM.Dispatch`
  can route it, supply the key it runs under, or refuse it, and can book what
  it cost when it returns. Without a dispatch the request is made exactly as
  configured. The host's `Wardrik.LLM.Client` makes it, and hands back each
  piece of the answer as it streams.

  ## Stopping early

  Three things stop a turn, and none of them lose what it has already
  produced, the first two asked through `Wardrik.Turn.Signal`:

    * `:yield` is read at an iteration boundary. The current model answer and
      any tools it asked for run to completion; the turn returns rather than
      asking again.

    * `:interrupt` is read at a boundary *and* on every piece of an answer
      as it streams, so it also stops an answer that is still arriving.
      Whatever text had streamed is added as the assistant's message,
      verbatim.

    * an expired deadline on the run stops the turn at a boundary, the way
      `:yield` does. It takes effect without a closing request, because
      spending more time is the one thing a deadline forbids.

  Neither message can land between a tool call and its result. A tool already
  running is not stopped — the mailbox is not read again until it returns — so
  a caller that must guarantee a stop needs to kill the process as well, or
  stop the one call with `Wardrik.LLM.ToolRunner.kill_call/2`.

  ## Stopping to ask

  A `Wardrik.Hook` that asks a person about a tool call parks the call. The
  turn comes back `{:waiting, :tools}` with nothing appended to the
  conversation, its batch in `:calls`, and `resume/2` finishes it once a
  person has decided.

  A hook that asks about a model call parks the turn before the call the same
  way, `{:waiting, :model}`, with the one call it waits on the model call
  itself, named `model`, so a person answers it the way they answer any
  other. Approving it makes the call; denying it fails the turn as
  `{:policy_denied, reason}`.

  A model call whose tries are spent, where its retry says to ask, parks the
  turn the same way, and the prompt says why: "The model failed 7 times:
  <reason>. Try again?". Approving it makes the call again with a fresh set
  of tries; denying it fails the turn as `{:model_failed, reason}`.

  A turn that waits is written down with no run, so it holds no
  credentials and runs no processes, and `under/2` gives it the run it
  resumes under.

  ## What the tools say first

  `new/2` asks each of the config's tools what it tells the model before the
  turn (see `c:Wardrik.Tool.context/1`), once, and every request the turn
  makes carries it after the system prompt. The turn keeps it, so a turn
  carried on after a lost node says what it began with. The labels of what a
  tool tells it are the turn's from the start.

  ## What the turn has read

  Once a call the turn made answers with something labelled (see
  `Wardrik.Call.label/2`), the turn carries the labels, and the run of every
  batch after it says so, for its hooks to weigh:
  `WardrikPolicy` holds a gated tool's call for a person after content from
  outside, since what the turn read may be what asked for it. A turn written
  down carries its labels, so one carried on after a lost node carries them
  still.

  What the turn read stays in the history it leaves, so a turn begun under a
  run that carries labels already, as `Wardrik.Agent` begins one on a
  history that holds labelled content, carries them from the start.

  ## Surviving a lost node

  A run with a journal, as `Wardrik.Agent` gives each turn it runs, is handed
  the turn, written down, before every batch of tool calls, and the batch runs
  only once the journal has answered `:ok`. A journal that does not answer
  ends the turn before anything runs. `recover/1` carries such a turn on, with
  the answer it had, so the calls it asked for keep their ids and a
  `Wardrik.Ledger` can say which already ran.

  ## A model call that fails

  A call that fails is handed to the run's `Wardrik.LLM.Retry`, with the
  failed try added to the request's attempts, which decides whether to ask
  again and after how long, and what happens once it asks again no more:
  `Wardrik.LLM.Retry.Backoff` by default. Each try goes through the hooks and
  the dispatch, which may send it to another model, and is its own
  `Wardrik.Event.ModelStarted` and `Wardrik.Event.ModelFinished`, with a
  `Wardrik.Event.ModelRetrying` before each wait. A retry answers under the
  message id of the first try with the try's number added, `.2` for the
  second, and a call a person approved under the id of their call added, so
  what a failed try had streamed is never taken for an answer. Once the
  retry asks again no more, the turn parks to ask a person, as above, or
  fails with the call's reason. `:interrupt` stops a wait, and a turn past
  its deadline fails with the call's reason rather than waiting.

  ## The iteration cap

  `max_iterations` on the config bounds the rounds of tool use. When the last
  round has run, the turn makes one more request with no tools and a closing
  note added to the system prompt, so it ends with an answer drawn from what
  it found rather than with a tool exchange nobody read.
  """
  require Logger

  alias Wardrik.Call
  alias Wardrik.Call.Pipeline
  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Event
  alias Wardrik.Hook
  alias Wardrik.Host
  alias Wardrik.LLM.Answer
  alias Wardrik.LLM.Attempt
  alias Wardrik.LLM.Client
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Retry
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Run
  alias Wardrik.Tool
  alias Wardrik.Trace
  alias Wardrik.Turn.Signal

  @enforce_keys [:context]
  defstruct [
    :run,
    :context,
    :answer,
    :revision,
    :error,
    :preamble,
    messages: [],
    remaining: :infinity,
    calls: [],
    state: :running,
    labels: []
  ]

  @type state() :: :running | {:waiting, :tools | :model} | :done | :failed

  @type t() :: %__MODULE__{
          run: Run.t() | nil,
          context: Conversation.t() | nil,
          answer: Answer.t() | nil,
          revision: String.t() | nil,
          error: term(),
          preamble: String.t() | nil,
          messages: [Conversation.message()],
          remaining: non_neg_integer() | :infinity,
          calls: [Call.t()],
          state: state(),
          labels: [Wardrik.Label.t()]
        }

  @streamed :wardrik_streamed_text
  @answered :wardrik_answered

  @closing "You have used every tool call available for this turn. Answer now from what you have, and say plainly what you could not verify."

  @doc """
  A turn to answer `context` under `run`, with the rounds its config allows,
  and what its tools tell the model first.
  """
  @spec new(Run.t(), Conversation.t()) :: t()
  def new(%Run{config: config} = run, %Conversation{} = context) do
    {preamble, labels} = Tool.context(config.tools, run)

    %__MODULE__{
      run: run,
      context: context,
      remaining: config.max_iterations,
      preamble: preamble,
      labels: Wardrik.Label.union(run.labels, labels)
    }
  end

  @doc "Runs `turn` until it is done, waits on a person, or fails."
  @spec run(t()) :: t()
  def run(%__MODULE__{state: :running, run: %Run{}} = turn), do: loop(turn)

  @doc "The turn under `run`, or under none for one that is written down."
  @spec under(t(), Run.t() | nil) :: t()
  def under(%__MODULE__{} = turn, run), do: %{turn | run: run}

  @doc """
  The turn with its context left out, for storing beside the history it
  began on; `load/2` makes it again.
  """
  @spec dump(t()) :: t()
  def dump(%__MODULE__{} = turn), do: %{turn | context: nil}

  @doc """
  Makes again the context `dump/1` left out: `history`, the conversation the
  turn began on, with what the turn added after it.
  """
  @spec load(t(), Conversation.t()) :: t()
  def load(%__MODULE__{} = turn, %Conversation{} = history),
    do: %{turn | context: Conversation.append(history, turn.messages)}

  @doc "The turn done, having added `messages` besides what it already had."
  @spec done(t(), [Conversation.message()]) :: t()
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

  @doc "The ids of the tool calls the turn's answer asked for."
  @spec call_ids(t()) :: [String.t()]
  def call_ids(%__MODULE__{answer: nil}), do: []

  def call_ids(%__MODULE__{answer: %Answer{message: message}}),
    do: message |> Assistant.calls() |> Enum.map(& &1.id)

  @doc "Whether the turn waits on a person before a model call rather than at a tool call."
  @spec model?(t()) :: boolean()
  def model?(%__MODULE__{state: state}), do: state == {:waiting, :model}

  @doc "Whether the turn waits under hooks other than `hooks`, by `Wardrik.Hook.revision/1`."
  @spec stale?(t(), [Wardrik.Hook.t()]) :: boolean()
  def stale?(%__MODULE__{revision: revision}, hooks), do: revision != Hook.revision(hooks)

  @doc """
  Finishes a waiting turn, applying one decision per waiting call.

  Approved calls go ahead now, without the hooks being asked again: the
  decision has been made, and asking again would park them forever. They run
  as a batch's calls do, each in a task of its own, so one that crashes or
  hangs is answered with why and the turn carries on. Each hook
  that asked hears of the approval through `Wardrik.Hook.approved/1`. A call that
  parked because it may already have run runs again once approved; one
  approved when a hook asked, and found by the ledger to have begun since,
  parks again to ask that. Denied calls are answered with the reason, which
  the model reads and can act on. A call with no decision stays waiting, so a
  person can answer them one at a time.

  A turn that parked under hooks other than its run's, by
  `Wardrik.Hook.revision/1`, has the run's hooks asked about every call a hook
  was waiting on before any decision is applied, and a decision about such a
  call is set aside: the call goes ahead, is refused, or waits again on what
  the hooks ask now. A call waiting on its tool or the ledger keeps its
  decision.
  """
  @spec resume(t(), Wardrik.Turn.decisions()) :: t()
  def resume(%__MODULE__{state: {:waiting, :model}, calls: [call]} = turn, decisions)
      when is_map(decisions) do
    case if(stale?(turn, turn.run.hooks), do: :redecide, else: Map.get(decisions, call.id)) do
      nil ->
        turn

      :redecide ->
        turn |> running() |> loop()

      decision ->
        case call |> Call.under(turn.run) |> Pipeline.answer(decision) do
          %Call{state: :approved} = approved -> turn |> running() |> loop(approved: approved)
          %Call{} = refused -> fail(turn, refusal(refused))
        end
    end
  end

  def resume(%__MODULE__{state: {:waiting, :tools}} = turn, decisions) when is_map(decisions) do
    stale? = stale?(turn, turn.run.hooks)
    run = batch(turn)
    calls = turn.calls |> Enum.map(&decide(&1, decisions, run, stale?)) |> ran(run)
    resumed = read(%{turn | calls: calls}, calls)

    if Enum.any?(resumed.calls, &Call.waiting?/1),
      do: %{resumed | revision: revision(turn.run)},
      else: finish(%{resumed | state: :running, revision: nil})
  end

  # A model call waits on its own tool only once its tries are spent.
  defp refusal(%Call{denied: denied} = call) do
    if Call.asked_by?(call, :tool),
      do: {:model_failed, denied.reason},
      else: {:policy_denied, denied.reason}
  end

  defp running(turn), do: %{turn | state: :running, calls: [], revision: nil}

  defp revision(%Run{hooks: hooks}), do: Hook.revision(hooks)

  defp decide(%Call{state: :waiting} = call, decisions, run, stale?) do
    if stale? and Call.asked_by_hook?(call),
      do: {:run, Call.reset(call)},
      else: decided(call, Map.get(decisions, call.id), run)
  end

  defp decide(%Call{} = call, _decisions, _run, _stale?), do: {:keep, call}

  defp decided(call, nil, _run), do: {:keep, call}

  defp decided(call, decision, run),
    do: {:run, call |> Call.under(run) |> Pipeline.answer(decision)}

  # The calls that go ahead run together, as a batch's calls do, each in a
  # task of its own; the rest keep their places.
  defp ran(decided, run) do
    done = ToolRunner.execute_many_async(for({:run, call} <- decided, do: call), run)

    {calls, []} =
      Enum.map_reduce(decided, done, fn
        {:run, _call}, [call | rest] -> {call, rest}
        {:keep, call}, rest -> {call, rest}
      end)

    calls
  end

  # A batch every call of which has been answered is appended, and the turn
  # goes on.
  defp finish(%__MODULE__{calls: calls, answer: answer} = turn) do
    {context, appended} = exchanged(turn.context, answer.message, ToolRunner.messages(calls))
    continue(turn, context, appended)
  end

  @doc """
  Carries on a turn the journal was handed before a batch: the batch runs,
  with the ledger answering for any call that already had, and the turn goes
  on from there.
  """
  @spec recover(t()) :: t()
  def recover(%__MODULE__{state: :running, run: %Run{}, answer: %Answer{}} = turn),
    do: advance(turn)

  # `opts` apply to the next model call alone.
  defp loop(%__MODULE__{run: run} = turn, opts \\ []) do
    cond do
      Run.expired?(run) -> out_of_time(turn)
      turn.remaining == 0 -> wrap_up(turn, opts)
      true -> iterate(turn, opts)
    end
  end

  defp out_of_time(turn) do
    Logger.warning("Turn reached its deadline, stopping with what it has")
    Event.emit(turn.run.source, %Event.DeadlineReached{message_count: length(turn.messages)})
    done(turn)
  end

  defp iterate(turn, opts) do
    case request(turn, turn.run, opts) do
      {:ok, answer} ->
        advance(%{turn | answer: answer})

      {:park, waiting} ->
        parked(turn, :model, [Call.under(waiting, nil)])

      {:interrupted, text} ->
        done(turn, partial(text))

      {:error, reason} ->
        Logger.warning("Error streaming text: #{inspect(reason)}")
        fail(turn, reason)
    end
  end

  defp partial(""), do: []
  defp partial(text), do: [Assistant.new(text)]

  # One last request without tools. Any tool call the model asks for anyway
  # is dropped, so the conversation never ends on an unanswered call.
  defp wrap_up(%__MODULE__{run: run} = turn, opts) do
    Logger.warning("Turn hit its iteration cap, answering without tools")

    case request(turn, %{run | config: %{run.config | tools: []}}, opts, true) do
      {:ok, %Answer{message: message}} ->
        done(turn, partial(Conversation.text(message)))

      {:park, waiting} ->
        parked(turn, :model, [Call.under(waiting, nil)])

      {:interrupted, text} ->
        done(turn, partial(text))

      {:error, reason} ->
        Logger.warning("Error streaming text: #{inspect(reason)}")
        fail(turn, reason)
    end
  end

  defp parked(turn, on, calls),
    do: %{turn | state: {:waiting, on}, calls: calls, revision: revision(turn.run)}

  # A request's system prompt: the config's, what the tools said as the turn
  # began, and the closing note on the last request of a turn at its cap.
  defp system(system, turn, closing?) do
    case Enum.reject(
           [system, turn.preamble, closing? && @closing],
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
  defp journal(%__MODULE__{run: %Run{journal: nil}}), do: :ok

  defp journal(%__MODULE__{run: %Run{journal: journal}, answer: answer} = turn) do
    case Assistant.calls(answer.message) do
      [] ->
        :ok

      _calls ->
        case GenServer.call(journal, {:checkpoint, under(turn, nil)}, :timer.seconds(30)) do
          :ok -> :ok
          {:error, reason} -> {:error, {:checkpoint_failed, reason}}
        end
    end
  catch
    :exit, reason -> {:error, {:checkpoint_failed, reason}}
  end

  # The turn reports that it waits; the agent holding it is what announces the
  # state change, because only it can say that `resume/2` will now work.
  defp handle(turn) do
    case handle_answer(batch(turn), turn.context, turn.answer) do
      {:done, messages} ->
        done(turn, messages)

      {:cont, context, messages, calls} ->
        turn |> read(calls) |> continue(context, messages)

      {:waiting, calls} ->
        turn |> read(calls) |> parked(:tools, calls)
    end
  end

  # The run a batch runs under: the turn's, for this round, carrying what
  # the turn has read.
  defp batch(turn), do: %{Run.batch(turn.run, rounds(turn)) | labels: turn.labels}

  # The turn, carrying what `calls` answered with.
  defp read(%__MODULE__{} = turn, calls),
    do: %{turn | labels: Enum.reduce(calls, turn.labels, &Wardrik.Label.union(&2, &1.labels))}

  defp continue(turn, context, messages) do
    turn = %{
      turn
      | context: context,
        answer: nil,
        calls: [],
        messages: turn.messages ++ messages
    }

    if Signal.stopping?(),
      do: done(turn),
      else: loop(%{turn | remaining: countdown(turn.remaining)})
  end

  defp countdown(:infinity), do: :infinity
  defp countdown(remaining), do: remaining - 1

  # Each round of tool use adds one assistant message to what the turn has
  # produced, so their count is the round a batch belongs to.
  defp rounds(%__MODULE__{messages: messages}),
    do: Enum.count(messages, &match?(%Assistant{}, &1))

  # The message a model call answers with is named by where the turn is: its
  # span and its round, so a turn replayed names it as it did the first time.
  defp message_id(%__MODULE__{run: %Run{source: source}} = turn, nil),
    do: "#{source.trace.span_id}.m#{rounds(turn)}"

  defp message_id(turn, %Call{id: id}), do: "#{message_id(turn, nil)}.#{id}"

  # A call a hook parks is never made, so it has no model events. `opts` hold
  # the call a person approved, which every try goes ahead as. `run` is the
  # turn's, or one whose config is narrowed for the last request of a turn at
  # its cap.
  defp request(%__MODULE__{} = turn, %Run{config: config} = run, opts, closing? \\ false) do
    config = %{config | system: system(config.system, turn, closing?)}
    request = Request.new(config, turn.context)
    asked(%{run | config: config}, request, message_id(turn, opts[:approved]), opts)
  end

  defp asked(%Run{} = run, %Request{} = request, message_id, opts) do
    case request |> Pipeline.model(run, opts[:approved]) |> Pipeline.decide() do
      %Call{state: :waiting} = waiting ->
        {:park, waiting}

      %Call{state: :denied, denied: denied} ->
        {:error, {:policy_denied, denied.reason}}

      call ->
        call
        |> make(tried_id(message_id, request))
        |> again(run, request, message_id, opts)
    end
  end

  defp tried_id(message_id, %Request{attempts: []}), do: message_id
  defp tried_id(message_id, %Request{attempts: tried}), do: "#{message_id}.#{length(tried) + 1}"

  defp again({{:error, reason} = failed, model_spec}, run, request, message_id, opts) do
    attempt = %Attempt{model_spec: model_spec, reason: reason, answered?: Process.get(@answered)}
    tried = Request.failed(request, attempt)

    case if(Run.expired?(run), do: :fail, else: Retry.again(run.retry, tried, run: run)) do
      {:again, wait, attempts} ->
        Logger.warning("Model call failed, asking again in #{wait}ms: #{inspect(reason)}")

        Event.emit(run.source, %Event.ModelRetrying{
          message_id: tried_id(message_id, request),
          attempt: length(tried.attempts),
          attempts: attempts,
          wait_ms: wait,
          reason: reason
        })

        if Signal.interrupted?(wait),
          do: {:interrupted, ""},
          else: asked(run, tried, message_id, opts)

      :ask ->
        {:park, tried |> Call.model(run) |> Call.wait(:tool, exhausted(tried))}

      :fail ->
        failed
    end
  end

  defp again({result, _model_spec}, _run, _request, _message_id, _opts), do: result

  defp exhausted(%Request{attempts: [last | _] = attempts}) do
    "The model failed #{times(length(attempts))}: #{String.slice(said(last.reason), 0, 200)}. " <>
      "Try again?"
  end

  defp times(1), do: "once"
  defp times(n), do: "#{n} times"

  defp said(%{__exception__: true} = error), do: Exception.message(error)
  defp said(reason), do: inspect(reason)

  # What a try came to, with the model it went to once the dispatch had
  # admitted it.
  defp make(%Call{run: %Run{source: source}} = call, message_id) do
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
        answer: answer(result),
        cost: made.cost
      }
    )

    {result, made.target.model_spec}
  end

  defp streamed(%Call{run: run} = call),
    do: Call.answer(call, call |> Pipeline.request() |> stream(run) |> settled())

  defp unsettled(%Call{result: {:error, reason, _text}}), do: {:error, reason}
  defp unsettled(%Call{result: result}), do: result

  defp answer({:ok, %Answer{} = answer}), do: answer
  defp answer(_failed), do: nil

  # A stream that failed once the provider had begun to answer settles with
  # the text that had streamed.
  defp settled({:error, reason}) do
    if Process.get(@answered), do: {:error, reason, streamed_text()}, else: {:error, reason}
  end

  defp settled(result), do: result

  defp stream(%Request{} = request, %Run{host: host, source: source}) do
    Client.stream(Host.llm(host), request, &emitted(&1, source))
  catch
    :interrupt -> {:interrupted, streamed_text()}
  end

  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome({:interrupted, _text}), do: {:error, :interrupted}
  defp outcome(_result), do: :ok

  defp streamed_text, do: @streamed |> Process.get([]) |> Enum.reverse() |> IO.iodata_to_binary()

  defp handle_answer(run, context, %Answer{message: message}) do
    case Assistant.calls(message) do
      [] -> {:done, [message]}
      calls -> settle_calls(run, context, message, calls)
    end
  end

  defp settle_calls(run, context, message, calls) do
    outcomes = ToolRunner.execute_many_async(calls, run)

    if ToolRunner.parked(outcomes) != [] do
      {:waiting, outcomes}
    else
      {context, messages} = exchanged(context, message, ToolRunner.messages(outcomes))
      {:cont, context, messages, outcomes}
    end
  end

  # The model's message and the results of the calls it asked for, in the
  # order it asked for them, added to `context`, with what was added.
  defp exchanged(context, message, results),
    do: {Conversation.append(context, [message | results]), [message | results]}

  # Each piece runs in this process, so `:interrupt` is read from the same
  # mailbox the boundary reads, once the piece is out. A throw escapes the
  # client, leaving what streamed so far recoverable.
  defp emitted(delta, source) do
    Process.put(@answered, true)
    published(delta, source)
    if Signal.interrupted?(), do: throw(:interrupt)
  end

  defp published({:text, text}, source) do
    Process.put(@streamed, [text | Process.get(@streamed, [])])
    Event.emit(source, %Event.Result{text: text})
  end

  defp published({:reasoning, text}, source), do: Event.emit(source, %Event.Thinking{text: text})
  defp published({:tool_call, call}, source), do: Event.emit(source, %Event.ToolCall{call: call})

  defimpl Wardrik.Turn do
    alias Wardrik.LLM.Turn

    defdelegate run(turn), to: Turn
    defdelegate resume(turn, decisions), to: Turn
    defdelegate recover(turn), to: Turn
    defdelegate waiting(turn), to: Turn
    defdelegate awaiting(turn, ref, owner), to: Turn
    defdelegate under(turn, run), to: Turn
    defdelegate stale?(turn, hooks), to: Turn
    defdelegate dump(turn), to: Turn
    defdelegate load(turn, history), to: Turn

    def status(%Turn{state: :done} = turn), do: {:done, turn.messages, turn.labels}
    def status(%Turn{state: {:waiting, _on}}), do: :waiting
    def status(%Turn{state: :failed, error: reason}), do: {:failed, reason}
  end
end
