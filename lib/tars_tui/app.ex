defmodule TarsTUI.App do
  @moduledoc """
  A full-screen terminal client for one agent.

  A `Tars.Event.Bus` subscriber holding no conversation state, so several can
  watch the same agent. Events are folded as they arrive and the frame is
  redrawn at most every #{50} milliseconds while they do, so the frame rate
  does not follow the token rate and keys are handled promptly. Five rows,
  top to bottom:

    1. **header**: the model, the agent, and whether tracing is on
    2. **transcript**: the answer rendered as markdown a line at a time, each
       span the turn opens and closes as an indented tree line, and each tool
       call with its arguments; pinned to the newest row until scrolled up,
       with one blank row kept under it
    3. **activity**: a spinner, the innermost work in flight and what it is
       doing, with the newest words of the model's reasoning while it
       reasons, on the left; streamed characters and elapsed time on the
       right
    4. **prompt**: accepts text at any time and grows with its draft, up to
       eight rows; a line entered while a turn runs is queued by `Tars.Agent`
       and echoed as such
    5. **meta**: tokens in and out, reasoning tokens, cost and requests on the
       left; prompts queued behind the running turn on the right

  Only text on the turn's root span is rendered as prose. Text streamed by
  delegated work appears as the tree of spans and tool calls.

  Keys: `Enter` sends, `Esc` interrupts, `Ctrl-T` toggles tracing, `Tab` moves
  focus to the transcript so `PageUp`/`PageDown`/`Home`/`End` scroll it,
  `Ctrl-D` quits. `/stop` and `/quit` do the same as the keys.
  """
  use Breeze.View
  import Breeze.Blocks

  alias Tars.Agent
  alias Tars.Event
  alias TarsTUI.Activity
  alias TarsTUI.Markdown
  alias TarsTUI.Render
  alias TarsTUI.Table
  alias TarsTUI.Text
  alias TarsTUI.Transcript
  alias TarsTUI.Usage
  alias TarsTUI.View

  @tick 100
  @frame_after 50
  @thinking_tail 240
  # Header, the spacer under the transcript, activity, and meta.
  @chrome_rows 4
  @max_prompt_rows 8
  @faint [:faint, :light_black]

  @typedoc "How a line typed at the prompt is interpreted."
  @type command() :: :blank | :quit | :stop | {:ask, String.t()}

  @doc "Interprets one line of input. Pure, so the vocabulary is testable alone."
  @spec command(String.t()) :: command()
  def command(line) do
    case String.trim(line) do
      "" -> :blank
      slash when slash in ["/quit", "/exit"] -> :quit
      "/stop" -> :stop
      text -> {:ask, text}
    end
  end

  @doc """
  Keybindings that work wherever focus is. Pass them as `:global_keybindings`
  when starting the session.
  """
  @spec keybindings() :: [{String.t(), String.t(), (map(), Breeze.Term.t() -> term())}]
  def keybindings do
    [
      {"Escape", "Stop", &__MODULE__.stop_turn/2},
      {"^t", "Trace", &__MODULE__.toggle_trace/2},
      {"^d", "Quit", &__MODULE__.quit/2}
    ]
  end

  @doc false
  def stop_turn(_event, term), do: {:noreply, interrupt(term)}

  @doc false
  def toggle_trace(_event, term),
    do: {:noreply, assign(term, verbose?: not term.assigns.verbose?)}

  @doc false
  def quit(_event, term), do: {:stop, term}

  @impl Breeze.View
  def mount(opts, term) do
    agent = Keyword.fetch!(opts, :agent)
    agent_id = Keyword.get(opts, :agent_id, agent)
    model = Keyword.get(opts, :model, "")
    width = width(term)

    # `:raw` delivers `{:tool_call, chunk}` with its arguments.
    :ok = Event.Bus.subscribe(agent_id, level: :raw)

    term =
      term
      |> assign(
        agent: agent,
        agent_id: agent_id,
        model: model,
        verbose?: Keyword.get(opts, :verbose, false),
        transcript: Transcript.new(width),
        activity: Activity.new(),
        answer: Markdown.new(),
        reasoning: Markdown.new(),
        thinking: "",
        usage: Usage.new(model),
        running?: false,
        frame: 0,
        frame_due?: false,
        started_at: nil,
        chars: 0,
        queued: 0,
        answering?: false,
        draft: ""
      )
      |> focus("prompt")

    {:ok, append_lines(term, banner())}
  end

  defp banner do
    [Text.tag("Enter sends · Esc stops · Ctrl-T trace · Tab scrolls · Ctrl-D quits", @faint)]
  end

  # -- render ----------------------------------------------------------------

  @impl Breeze.View
  def render(assigns) do
    width = assigns.breeze.terminal.width
    height = assigns.breeze.terminal.height

    if wrap_width(width) != assigns.transcript.width do
      send(self(), {:rewrap, wrap_width(width)})
    end

    prompt_height = prompt_rows(assigns.draft, width) + 2

    assigns =
      assign(assigns,
        source: Transcript.source(assigns.transcript),
        log_height: max(height - @chrome_rows - prompt_height, 1),
        prompt_class: "block w-full h-#{prompt_height} bg-none border-primary",
        header: header(assigns),
        status: status(assigns, width),
        meta: meta(assigns, width)
      )

    ~H"""
    <box class="block w-screen h-screen overflow-hidden">
      <box class="block w-full h-1 overflow-hidden">{@header}</box>
      <box
        id="log"
        focusable
        implicit={TarsTUI.Scroll}
        scroll-autoscroll="bottom"
        class={"block w-full overflow-scroll scrollbar-arrows h-#{@log_height}"}
      >
        {@source}
      </box>
      <box class="block w-full h-1 overflow-hidden">
      </box>
      <box class="block w-full h-1 overflow-hidden">{@status}</box>
      <.textarea
        id="prompt"
        br-change="draft"
        br-submit="ask"
        textarea-value={@draft}
        textarea-placeholder="Ask anything · /stop · /quit"
        textarea-prefix="› "
        textarea-submit-on-enter={true}
        class={@prompt_class}
      />
      <box class="block w-full h-1 overflow-hidden">{@meta}</box>
    </box>
    """
  end

  # Rows the draft occupies inside the box: one per line, more when a line
  # wraps, capped so the transcript keeps most of the screen.
  defp prompt_rows(draft, width) do
    inner = max(width - 6, 10)

    draft
    |> String.split("\n")
    |> Enum.sum_by(&max(ceil(String.length(&1) / inner), 1))
    |> min(@max_prompt_rows)
  end

  defp header(assigns) do
    [
      Render.tag(" tars", [:bright, :cyan]),
      if(assigns.verbose?, do: Render.tag(" [trace]", :yellow), else: ""),
      Render.dim(" · #{inspect(assigns.model)} · #{inspect(assigns.agent_id)}")
    ]
    |> Enum.join()
  end

  defp status(%{running?: false}, width) do
    left = Text.tag(" idle · type a prompt and press Enter", @faint)
    right = Text.tag("Esc stop · Ctrl-T trace · Tab scroll · Ctrl-D quit ", @faint)
    Render.line(Render.justify(left, right, width))
  end

  defp status(assigns, width) do
    span = Activity.innermost(assigns.activity)
    right = Text.tag([chars(assigns.chars), elapsed(assigns), " "], @faint)
    label = Text.truncate(label(span), max(div(width, 3), 20))
    head = [" ", Text.tag(View.spinner(assigns.frame), :cyan), " ", label]
    room = width - Text.length(right) - Text.length(head) - 4
    left = [head, doing(span, assigns.thinking, room)]

    Render.line(Render.justify(left, right, width))
  end

  defp label(nil), do: Text.tag("working", @faint)
  defp label(%{name: nil}), do: Text.tag("working", @faint)
  defp label(%{name: name}), do: Text.tag(name, :cyan)

  # The newest words of the reasoning, in the room left on the row.
  defp doing(%{doing: "thinking"}, thinking, room) when thinking != "" do
    Text.tag([" · ", Text.tag(newest(thinking, max(room, 8)), :italic)], @faint)
  end

  defp doing(%{doing: doing}, _thinking, _room) when is_binary(doing) do
    Text.tag(" · #{doing}", @faint)
  end

  defp doing(_span, _thinking, _room), do: []

  # The last `room` columns of `text`, cut at a word and marked as a cut.
  defp newest(text, room) do
    text = Render.squash(text)
    over = String.length(text) - room

    if over > 0 do
      tail = String.slice(text, over + 1, room - 1)

      case String.split(tail, " ", parts: 2) do
        [_partial, words] -> "…" <> words
        [_whole] -> "…" <> tail
      end
    else
      text
    end
  end

  defp chars(0), do: ""
  defp chars(n), do: "#{Usage.count(n)} chars · "

  defp meta(assigns, width) do
    left = Text.tag(" " <> Usage.summary(assigns.usage), @faint)
    right = Text.tag(queued(assigns.queued), @faint)
    Render.line(Render.justify(left, right, width))
  end

  defp elapsed(%{started_at: started_at}) when is_integer(started_at) do
    "#{div(now() - started_at, 1_000)}s"
  end

  defp elapsed(_assigns), do: ""

  defp queued(0), do: ""
  defp queued(1), do: "1 prompt queued "
  defp queued(n), do: "#{n} prompts queued "

  # -- input -----------------------------------------------------------------

  @impl Breeze.View
  def handle_event("draft", %{value: value}, term), do: {:noreply, assign(term, draft: value)}

  def handle_event("ask", %{value: value}, term) do
    term = term |> assign(draft: "") |> reset("prompt")

    case command(value) do
      :blank -> {:noreply, term}
      :quit -> {:stop, term}
      :stop -> {:noreply, interrupt(term)}
      {:ask, text} -> {:noreply, ask(term, text)}
    end
  end

  def handle_event(_name, _event, term), do: {:noreply, term}

  defp ask(term, text) do
    :ok = Agent.ask(term.assigns.agent, text)

    if term.assigns.running? do
      term
      |> assign(queued: term.assigns.queued + 1)
      |> append_lines([
        "",
        [prompt("»"), Text.tag(text, :bright), Text.tag("  · queued", @faint)]
      ])
    else
      append_lines(term, ["", [prompt("›"), Text.tag(text, :bright)]])
    end
  end

  defp interrupt(term) do
    :ok = Agent.interrupt(term.assigns.agent)
    term
  end

  # -- events ----------------------------------------------------------------

  # An event changes state without redrawing; the frame due after it does.
  @impl Breeze.View
  def handle_info(%Event{} = event, term) do
    term = handle(event, fold(term, event))
    {:noreply, frame_due(term), invalidate: false}
  end

  def handle_info(:frame, term), do: {:noreply, assign(term, frame_due?: false)}

  def handle_info(:tick, %{assigns: %{running?: true}} = term) do
    schedule_tick()
    {:noreply, assign(term, frame: term.assigns.frame + 1)}
  end

  def handle_info(:tick, term), do: {:noreply, term}

  def handle_info({:rewrap, width}, term) do
    {:noreply, assign(term, transcript: Transcript.rewrap(term.assigns.transcript, width))}
  end

  def handle_info(_message, term), do: {:noreply, term}

  defp frame_due(%{assigns: %{frame_due?: true}} = term), do: term

  defp frame_due(term) do
    Process.send_after(self(), :frame, @frame_after)
    assign(term, frame_due?: true)
  end

  # A turn starts a fresh tree.
  defp fold(term, %Event{payload: {:turn_started, _questions}} = event) do
    term
    |> assign(
      activity: Activity.fold(Activity.new(), event, now: now()),
      answer: Markdown.new(),
      reasoning: Markdown.new(),
      thinking: "",
      chars: 0,
      answering?: false
    )
  end

  defp fold(term, event) do
    assign(term, activity: Activity.fold(term.assigns.activity, event, now: now()))
  end

  # -- turn lifecycle

  defp handle(%Event{payload: {:turn_started, _questions}} = event, term) do
    schedule_tick()

    term
    |> assign(running?: true, frame: 0, started_at: now(), queued: 0)
    |> trace(event)
  end

  defp handle(%Event{payload: {:turn_finished, _messages}} = event, term) do
    term |> settle() |> trace(event) |> assign(running?: false)
  end

  defp handle(%Event{payload: {:turn_interrupted, stats}} = event, term) do
    term
    |> settle()
    |> trace(event)
    |> append(View.interrupted(stats))
    |> assign(running?: false)
  end

  defp handle(%Event{payload: {:turn_failed, reason}} = event, term) do
    term
    |> settle()
    |> trace(event)
    |> append(View.error(reason))
    |> assign(running?: false)
  end

  # -- the tree

  defp handle(%Event{payload: {:span_started, _name}} = event, term), do: span(term, event)

  defp handle(%Event{payload: {:span_finished, _outcome, _ms}} = event, term),
    do: span(term, event)

  defp handle(%Event{payload: {:tool_call, call}} = event, term) do
    case tool_call(call) do
      nil ->
        term

      line ->
        indent = indent(term, event)
        room = term.assigns.transcript.width - String.length(indent)
        append(term, [indent, Text.truncate(line, max(room, 8))])
    end
  end

  # -- streaming, root span only

  defp handle(%Event{payload: {:result, text}} = event, term) do
    if Event.root?(event) do
      {lines, answer} = Markdown.push(term.assigns.answer, text)

      term
      |> assign(answer: answer, chars: term.assigns.chars + String.length(text))
      |> answer_lines(lines)
    else
      term
    end
  end

  defp handle(%Event{payload: {:thinking, text}} = event, term) do
    term = assign(term, thinking: tail(term.assigns.thinking <> text))

    if Event.root?(event) do
      {lines, reasoning} = Markdown.push(term.assigns.reasoning, text)
      term = assign(term, reasoning: reasoning)
      if term.assigns.verbose?, do: append_lines(term, reasoning_lines(lines)), else: term
    else
      term
    end
  end

  # -- usage

  defp handle(%Event{payload: {:meta, chunk}, source: source}, term) do
    assign(term, usage: Usage.observe(term.assigns.usage, source.trace.span_id, chunk))
  end

  defp handle(%Event{payload: {:model_finished, _outcome, _ms}, source: source} = event, term) do
    term
    |> assign(usage: Usage.settle(term.assigns.usage, source.trace.span_id))
    |> trace(event)
  end

  defp handle(%Event{payload: {:chunk, _chunk}}, term), do: term

  defp handle(%Event{} = event, term), do: trace(term, event)

  # -- helpers ---------------------------------------------------------------

  defp span(term, %Event{source: source}) do
    span = Activity.fetch(term.assigns.activity, source.trace.span_id)
    depth = Activity.depth(term.assigns.activity, source.trace.span_id)

    term
    |> append(View.span(span, depth, now(), term.assigns.transcript.width))
    |> failure(span, depth)
  end

  # The span line is clipped to one row, so a failure's reason gets its own
  # wrapped lines under it.
  defp failure(term, %{status: :error, error: reason}, depth) do
    indent = String.duplicate("  ", depth + 2)
    append(term, Text.tag([indent, "↳ ", Render.squash(inspect(reason))], :red))
  end

  defp failure(term, _span, _depth), do: term

  # One line per complete call; a chunk without arguments is partial.
  defp tool_call(%{name: name, arguments: arguments})
       when is_binary(name) and is_map(arguments) and map_size(arguments) > 0 do
    Text.tag("  ⇢ #{name} #{Render.squash(JSON.encode!(arguments))}", @faint)
  end

  defp tool_call(_call), do: nil

  defp indent(term, %Event{source: source}) do
    depth = Activity.depth(term.assigns.activity, source.trace.span_id)
    String.duplicate("  ", depth)
  end

  defp reasoning_lines(lines), do: Enum.map(lines, &View.reasoning/1)

  # Flushes the unfinished last line of the answer and the reasoning.
  defp settle(term) do
    {answer, _} = Markdown.flush(term.assigns.answer)
    {reasoning, _} = Markdown.flush(term.assigns.reasoning)

    term =
      if term.assigns.verbose?, do: append_lines(term, reasoning_lines(reasoning)), else: term

    answer_lines(term, answer)
  end

  defp trace(%{assigns: %{verbose?: true}} = term, %Event{payload: payload}) do
    case View.trace(payload) do
      nil -> term
      line -> append(term, line)
    end
  end

  defp trace(term, _event), do: term

  defp prompt(glyph), do: Text.tag(glyph <> " ", [:bright, :cyan])

  # The answer is one block: a blank line, a bullet on its first line, and the
  # rest indented under it. A table takes its indent as a table, and one that
  # opens the answer takes the bullet's row for itself.
  defp answer_lines(term, []), do: term

  defp answer_lines(%{assigns: %{answering?: false}} = term, [first | rest]) do
    term
    |> assign(answering?: true)
    |> append_lines(["" | lead(first) ++ Enum.map(rest, &indented/1)])
  end

  defp answer_lines(term, lines), do: append_lines(term, Enum.map(lines, &indented/1))

  defp lead(%Table{} = table), do: [Text.tag("⏺", :green), indented(table)]
  defp lead(line), do: [[Text.tag("⏺ ", :green), line]]

  defp indented(%Table{} = table), do: %{table | indent: 2}
  defp indented(line), do: ["  ", line]

  defp append(term, data) do
    assign(term, transcript: Transcript.append(term.assigns.transcript, data))
  end

  defp append_lines(term, lines) do
    assign(term, transcript: Transcript.append_all(term.assigns.transcript, lines))
  end

  # Kept as it arrived, so a chunk ending in a space still separates words;
  # `newest/2` squashes it for the row.
  defp tail(text) do
    over = String.length(text) - @thinking_tail
    if over > 0, do: String.slice(text, over, @thinking_tail), else: text
  end

  defp width(%{terminal: %{size: %{width: width}}}) when is_integer(width), do: wrap_width(width)
  defp width(_term), do: wrap_width(100)

  # The scroll block keeps one column for its scrollbar and clips inside it.
  defp wrap_width(width), do: max(width - 4, 10)

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick)

  defp now, do: System.monotonic_time(:millisecond)
end
