defmodule TarsTUI.App.Conversation do
  @moduledoc """
  Conversation display state, streamed markdown, replay, and tool exchanges.

  The active display is projected to Breeze assigns by `App.Display`; saved
  agent views use this struct directly. No terminal, subscriptions, or timers
  enter the reducer. The caller supplies the clock, tracing preference, and
  whether the transcript follows its tail for each operation.

  Live status comes from the latest agent snapshot when restoring a saved view;
  draft, transcript, usage, and scroll position belong to the saved display.
  """

  alias Tars.Delegation
  alias Tars.Event
  alias Tars.LLM
  alias TarsTUI.Activity
  alias TarsTUI.Exchange
  alias TarsTUI.History
  alias TarsTUI.Line
  alias TarsTUI.Markdown
  alias TarsTUI.Render
  alias TarsTUI.Table
  alias TarsTUI.Text
  alias TarsTUI.Transcript
  alias TarsTUI.Usage
  alias TarsTUI.View
  @thinking_tail 240

  # Breeze exposes the active state as assigns; this struct defines the display
  # projection and is also the saved value when connecting to another agent.
  @kept [
    :generation,
    :trace_id,
    :activity,
    :unread,
    :transcript,
    :answer,
    :reasoning,
    :thinking,
    :chars,
    :answering?,
    :usage,
    :draft,
    :history,
    :delegations,
    :seen,
    :parked,
    :started_at,
    :tail,
    :tools,
    :answer_text,
    :search
  ]
  @fields @kept ++ [:running?, :queued, :scroll, :prompt]
  defstruct @fields

  @type t :: %__MODULE__{
          transcript: Transcript.t() | nil,
          draft: String.t() | nil,
          answer_text: String.t() | nil,
          running?: boolean() | nil,
          queued: non_neg_integer() | nil
        }
  @type options :: [now: integer(), verbose?: boolean(), pinned?: boolean()]

  @doc "An empty display, independent of subscriptions and terminal widgets."
  @spec new(pos_integer(), String.t()) :: t()
  def new(width, model) do
    %__MODULE__{
      activity: Activity.new(),
      transcript: Transcript.new(width),
      answer: Markdown.new(),
      reasoning: Markdown.new(),
      thinking: "",
      chars: 0,
      answering?: false,
      tail: [],
      usage: Usage.new(model),
      unread: 0,
      draft: "",
      history: History.new(),
      delegations: Delegation.new(),
      tools: [],
      answer_text: "",
      seen: 0,
      parked: [],
      running?: false,
      queued: 0,
      scroll: %{},
      prompt: %{}
    }
  end

  @doc "Reads only conversation-owned fields from the active view."
  def from_assigns(assigns), do: struct!(__MODULE__, Map.take(assigns, @fields))

  @doc "The active display projection, without saved widget state."
  def to_assigns(%__MODULE__{} = state),
    do: state |> Map.from_struct() |> Map.drop([:scroll, :prompt])

  @doc "Saved display fields; current snapshot identity and liveness win on restore."
  def restored_assigns(%__MODULE__{} = state),
    do: state |> Map.take(@kept) |> Map.drop([:generation, :trace_id, :activity])

  @doc "Folds an agent event without IO, timers, or access to a terminal."
  @spec apply_event(t(), Event.t(), options()) :: t()
  def apply_event(%__MODULE__{} = state, event, opts) do
    project(state, opts, fn projection ->
      handle_projection(event, fold_projection(projection, event))
    end)
  end

  @doc false
  def playback(%__MODULE__{} = state, messages, opts),
    do: project(state, opts, fn projection -> playback_projection(projection, messages) end)

  @doc false
  def parked_notice(%__MODULE__{} = state, calls, opts),
    do: project(state, opts, fn projection -> parked_notice_projection(projection, calls) end)

  @doc false
  def question(%__MODULE__{} = state, text, opts),
    do: project(state, opts, fn projection -> question_projection(projection, text) end)

  @doc false
  def settle(%__MODULE__{} = state, opts),
    do: project(state, opts, fn projection -> settle_projection(projection) end)

  @doc false
  def append(%__MODULE__{} = state, data, opts),
    do: project(state, opts, fn projection -> append_projection(projection, data) end)

  @doc false
  def append_lines(%__MODULE__{} = state, lines, opts),
    do: project(state, opts, fn projection -> append_lines_projection(projection, lines) end)

  defp project(state, opts, fun) do
    projection = %{
      state: state,
      now: Keyword.fetch!(opts, :now),
      verbose?: Keyword.fetch!(opts, :verbose?),
      pinned?: Keyword.fetch!(opts, :pinned?)
    }

    projection |> fun.() |> Map.fetch!(:state) |> tailed()
  end

  # The answer's unfinished line, wrapped as the rows the transcript draws
  # under its own, so text shows as it arrives rather than when its line ends.
  # It leads with the answer marker until a line has taken it.
  defp tailed(%__MODULE__{} = state) do
    %{state | tail: state.answer |> Markdown.tail() |> tail_rows(state)}
  end

  defp tail_rows(nil, _state), do: []

  defp tail_rows(line, %{answering?: false, transcript: transcript}),
    do: [[] | wrapped([Text.tag("⏺ ", :green), line], transcript)]

  defp tail_rows(line, %{transcript: transcript}), do: wrapped(["  ", line], transcript)

  defp wrapped(data, transcript), do: data |> Line.segments() |> Line.wrap(transcript.width)

  defp assign(projection, values),
    do: %{projection | state: struct!(projection.state, values)}

  # The conversation as the transcript would have shown it: what the person
  # asked, what the agent answered, and each tool call with what it returned.
  defp playback_projection(projection, messages), do: Enum.reduce(messages, projection, &play/2)

  defp play(%{role: :user} = message, projection),
    do: question_projection(projection, LLM.Context.text(message))

  defp play(%{role: :assistant} = message, projection) do
    projection |> say(LLM.Context.text(message)) |> calls(message.tool_calls || [])
  end

  defp play(%{role: :tool} = message, projection) do
    output = LLM.Context.text(message)
    ok? = tool_ok?(message, output)
    name = message.name || "tool"

    projection
    |> append_projection(View.tool_result(name, output, ok?))
    |> assign(
      tools: Exchange.finish(projection.state.tools, message.tool_call_id, name, output, ok?)
    )
  end

  defp play(_system_message, projection), do: projection

  defp say(projection, ""), do: projection

  defp say(projection, text) do
    {streamed, answer} = Markdown.push(Markdown.new(), text)
    {rest, _answer} = Markdown.flush(answer)

    projection |> assign(answering?: false, answer_text: text) |> answer_lines(streamed ++ rest)
  end

  defp calls(projection, tool_calls) do
    Enum.reduce(tool_calls, projection, fn call, projection ->
      %{id: id, name: name, arguments: arguments} = ReqLLM.ToolCall.from_map(call)

      projection
      |> append_projection(View.tool_call(name, arguments))
      |> assign(tools: Exchange.call(projection.state.tools, id, name, arguments))
    end)
  end

  # A result is a failure when the runner marked it so, or when the tool
  # itself reported one through `Tars.Tool.Result.error/1`.
  defp tool_ok?(%{metadata: %{is_error: true}}, _output), do: false

  defp tool_ok?(_message, output) do
    not match?({:ok, %{"ok" => false}}, JSON.decode(output))
  end

  defp parked_notice_projection(projection, []), do: projection

  defp parked_notice_projection(projection, calls),
    do: append_projection(projection, View.parked(calls))

  defp question_projection(projection, text),
    do: append_lines_projection(projection, ["", View.question(text)])

  # A turn starts a fresh tree.
  defp fold_projection(projection, %Event{payload: {:turn_started, _questions}} = event) do
    projection
    |> assign(
      delegations: Delegation.fold(projection.state.delegations, event),
      activity: Activity.fold(Activity.new(), event, now: projection.now),
      trace_id: event.source.trace.trace_id,
      answer: Markdown.new(),
      reasoning: Markdown.new(),
      thinking: "",
      chars: 0,
      answering?: false,
      answer_text: ""
    )
  end

  defp fold_projection(projection, event) do
    assign(projection,
      activity: Activity.fold(projection.state.activity, event, now: projection.now),
      delegations: Delegation.fold(projection.state.delegations, event)
    )
  end

  # -- turn lifecycle

  defp handle_projection(%Event{payload: {:turn_started, _questions}} = event, projection) do
    projection
    |> assign(running?: true, parked: [], started_at: projection.now, queued: 0)
    |> trace(event)
  end

  # Answered calls leave the parked list, and the turn is running again; what
  # is still parked comes back with the next `:turn_parked`.
  defp handle_projection(%Event{payload: {:turn_resumed, decisions}} = event, projection) do
    parked =
      Enum.reject(projection.state.parked, fn {call, _prompt} ->
        Map.has_key?(decisions, call.id)
      end)

    projection
    |> assign(running?: true, parked: parked, started_at: projection.now)
    |> trace(event)
  end

  defp handle_projection(%Event{payload: {:turn_finished, _messages}} = event, projection) do
    projection |> settle_projection() |> trace(event) |> assign(running?: false, parked: [])
  end

  defp handle_projection(%Event{payload: {:turn_interrupted, stats}} = event, projection) do
    projection
    |> settle_projection()
    |> trace(event)
    |> append_projection(View.interrupted(stats))
    |> assign(running?: false, parked: [])
  end

  defp handle_projection(%Event{payload: {:turn_parked, calls}} = event, projection) do
    projection
    |> settle_projection()
    |> trace(event)
    |> append_projection(View.parked(calls))
    |> assign(running?: false, parked: calls)
  end

  defp handle_projection(%Event{payload: {:turn_failed, reason}} = event, projection) do
    projection
    |> settle_projection()
    |> trace(event)
    |> append_projection(View.error(reason))
    |> assign(running?: false, parked: [])
  end

  # -- the tree

  defp handle_projection(%Event{payload: {:span_started, _name}} = event, projection),
    do: span(projection, event)

  defp handle_projection(%Event{payload: {:span_finished, _outcome, _ms}} = event, projection),
    do: span(projection, event)

  defp handle_projection(%Event{payload: {:tool_call, call}} = event, projection) do
    case tool_call(call) do
      nil ->
        projection

      line ->
        indent = indent(projection, event)
        room = projection.state.transcript.width - String.length(indent)
        id = call.metadata[:id]

        projection
        |> append_projection([indent, Text.truncate(line, max(room, 8))])
        |> assign(tools: Exchange.call(projection.state.tools, id, call.name, call.arguments))
    end
  end

  defp handle_projection(%Event{payload: {:tool_finished, id, name, result}} = event, projection) do
    {output, ok?} =
      case result do
        {:ok, output} -> {output_text(output), true}
        {:error, why} -> {Render.squash(inspect(why)), false}
      end

    projection
    |> assign(tools: Exchange.finish(projection.state.tools, id, name, output, ok?))
    |> trace(event)
  end

  defp handle_projection(%Event{payload: {:tool_denied, id, name, reason}} = event, projection) do
    projection
    |> assign(tools: Exchange.finish(projection.state.tools, id, name, reason, false))
    |> trace(event)
  end

  # -- streaming, root span only

  defp handle_projection(%Event{payload: {:result, text}} = event, projection) do
    if Event.root?(event) do
      {lines, answer} = Markdown.push(projection.state.answer, text)

      projection
      |> assign(
        answer: answer,
        chars: projection.state.chars + String.length(text),
        answer_text: projection.state.answer_text <> text
      )
      |> answer_lines(lines)
    else
      projection
    end
  end

  defp handle_projection(%Event{payload: {:thinking, text}} = event, projection) do
    projection = assign(projection, thinking: tail(projection.state.thinking <> text))

    if Event.root?(event) do
      {lines, reasoning} = Markdown.push(projection.state.reasoning, text)
      projection = assign(projection, reasoning: reasoning)

      if projection.verbose?,
        do: append_lines_projection(projection, reasoning_lines(lines)),
        else: projection
    else
      projection
    end
  end

  # -- usage

  defp handle_projection(%Event{payload: {:meta, chunk}, source: source}, projection) do
    assign(projection, usage: Usage.observe(projection.state.usage, source.trace.span_id, chunk))
  end

  defp handle_projection(
         %Event{payload: {:model_finished, _outcome, _ms}, source: source} = event,
         projection
       ) do
    projection
    |> assign(usage: Usage.settle(projection.state.usage, source.trace.span_id))
    |> trace(event)
  end

  defp handle_projection(%Event{payload: {:chunk, _chunk}}, projection), do: projection

  defp handle_projection(%Event{} = event, projection), do: trace(projection, event)

  # -- helpers ---------------------------------------------------------------

  defp span(projection, %Event{source: source}) do
    span = Activity.fetch(projection.state.activity, source.trace.span_id)
    depth = Activity.depth(projection.state.activity, source.trace.span_id)

    projection
    |> append_projection(
      View.span(span, depth, projection.now, projection.state.transcript.width)
    )
    |> failure(span, depth)
  end

  # The span line is clipped to one row, so a failure's reason gets its own
  # wrapped lines under it.
  defp failure(projection, %{status: :error, error: reason}, depth) do
    indent = String.duplicate("  ", depth + 2)
    append_projection(projection, Text.tag([indent, "↳ ", Render.squash(inspect(reason))], :red))
  end

  defp failure(projection, _span, _depth), do: projection

  # One line per complete call; a chunk without arguments is partial.
  defp tool_call(%{name: name, arguments: arguments})
       when is_binary(name) and is_map(arguments) and map_size(arguments) > 0 do
    View.tool_call(name, arguments)
  end

  defp tool_call(_call), do: nil

  defp indent(projection, %Event{source: source}) do
    depth = Activity.depth(projection.state.activity, source.trace.span_id)
    String.duplicate("  ", depth)
  end

  defp reasoning_lines(lines), do: Enum.map(lines, &View.reasoning/1)

  # Flushes the unfinished last line of the answer and the reasoning.
  defp settle_projection(projection) do
    {answer, _} = Markdown.flush(projection.state.answer)
    {reasoning, _} = Markdown.flush(projection.state.reasoning)

    projection =
      if projection.verbose?,
        do: append_lines_projection(projection, reasoning_lines(reasoning)),
        else: projection

    projection
    |> answer_lines(answer)
    |> assign(answer: Markdown.new(), reasoning: Markdown.new())
  end

  defp trace(%{verbose?: true} = projection, %Event{payload: payload}) do
    case View.trace(payload) do
      nil -> projection
      line -> append_projection(projection, line)
    end
  end

  defp trace(projection, _event), do: projection

  # The answer is one block: a blank line, a bullet on its first line, and the
  # rest indented under it. A table takes its indent as a table, and one that
  # opens the answer takes the bullet's row for itself.
  defp answer_lines(projection, []), do: projection

  defp answer_lines(%{state: %{answering?: false}} = projection, [first | rest]) do
    projection
    |> assign(answering?: true)
    |> append_lines_projection(["" | lead(first) ++ Enum.map(rest, &indented/1)])
  end

  defp answer_lines(projection, lines),
    do: append_lines_projection(projection, Enum.map(lines, &indented/1))

  defp lead(%Table{} = table), do: [Text.tag("⏺", :green), indented(table)]

  defp lead(line), do: [[Text.tag("⏺ ", :green), line]]

  defp indented(%Table{} = table), do: %{table | indent: 2}

  defp indented(line), do: ["  ", line]

  # A tool's result as the inspector shows it: text as it is, anything else as
  # JSON, or as Elixir when it does not encode.
  defp output_text(output) when is_binary(output), do: output

  defp output_text(output) do
    JSON.encode!(output)
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] -> inspect(output)
  end

  # Rows added while the transcript is scrolled up are counted as unread.
  defp append_projection(projection, data), do: grow(projection, &Transcript.append(&1, data))

  defp append_lines_projection(projection, lines),
    do: grow(projection, &Transcript.append_all(&1, lines))

  defp grow(projection, fun) do
    before = Transcript.rows(projection.state.transcript)
    transcript = fun.(projection.state.transcript)
    added = Transcript.rows(transcript) - before

    unread =
      if pinned?(projection) or added == 0,
        do: projection.state.unread,
        else: projection.state.unread + added

    assign(projection, transcript: transcript, unread: unread)
  end

  defp pinned?(projection), do: projection.pinned?

  # Kept as it arrived, so a chunk ending in a space still separates words;
  # `newest/2` squashes it for the row.
  defp tail(text) do
    over = String.length(text) - @thinking_tail
    if over > 0, do: String.slice(text, over, @thinking_tail), else: text
  end
end
