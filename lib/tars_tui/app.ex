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

  A fleet panel down the right lists every agent in the cluster, what each is
  doing, and which node it is on. It is driven by `Tars.Fleet.watch/1` rather
  than polling. `Ctrl-F` focuses it; `Up` and `Down` move through the agents
  and `Enter` connects to the one under the cursor. `Ctrl-F` again puts the
  panel away. `/spawn NAME [node=NODE] [prompt]` starts an agent with the
  same `:spawn_opts` this client's own agent was given, on the named node if
  one is given, attaches to it, and sends it the prompt. `/connect NAME`
  attaches this client to an agent under its own org and user: the transcript
  is cleared and the agent's conversation played back, so what is on screen is
  that agent's. `/move NAME node=NODE` restarts
  an agent on another node with the conversation it has. `/kill NAME` stops
  an agent and deletes its store, and `/kill PREFIX/` does that to every
  running agent under a prefix. Neither touches the agent this client is
  attached to. `/help` lists all of this.

  Attaching works the same way on start, so an agent named on the command line
  that already has a conversation shows it.

  The focused pane shows it in the primary colour: the prompt's box, the
  fleet panel's border, or the rule under the transcript. `Tab` cycles the
  prompt, the transcript and the panel, and nothing else.

  Keys: `Enter` sends, `Esc` interrupts, `Ctrl-T` toggles tracing, `Ctrl-F`
  focuses the fleet panel, `Tab` moves focus to the transcript so
  `PageUp`/`PageDown`/`Home`/`End` scroll it, `Ctrl-D` quits. `/stop` and
  `/quit` do the same as the keys.
  """
  use Breeze.View
  import Breeze.Blocks

  alias Tars.Agent
  alias Tars.Event
  alias Tars.Fleet
  alias Tars.LLM
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
  # The fleet republishes on every transition, so a busy turn would redraw the
  # panel constantly. One refresh per window is enough to read.
  @fleet_after 200
  @min_log_width 40
  @thinking_tail 240
  # Header, the status row, and meta.
  @chrome_rows 3
  @max_prompt_rows 8
  @faint [:faint, :light_black]

  @typedoc "How a line typed at the prompt is interpreted."
  @type command() ::
          :blank
          | :quit
          | :stop
          | :approve
          | :fleet
          | :help
          | {:deny, String.t() | nil}
          | {:spawn, String.t(), options(), String.t() | nil}
          | {:move, String.t(), options()}
          | {:connect, String.t()}
          | {:kill, String.t()}
          | {:ask, String.t()}

  @typedoc "The `key=value` words a command was given."
  @type options() :: %{String.t() => String.t()}

  @default_denial "Denied by the person watching."

  @doc """
  Interprets one line of input. Pure, so the vocabulary is testable alone.

  While a turn is parked the vocabulary grows: a bare `y` or `n` answers the
  question, and `n` followed by anything denies with that as the reason. Only a
  bare word counts, so a question that happens to start with "no" is still a
  question.
  """
  @spec command(String.t(), boolean()) :: command()
  def command(line, parked? \\ false) do
    case String.trim(line) do
      "" -> :blank
      "/" <> _rest = slash -> slash(slash)
      text -> answer(text, parked?)
    end
  end

  defp slash(line) do
    case line do
      slash when slash in ["/quit", "/exit"] -> :quit
      "/stop" -> :stop
      "/help" -> :help
      other -> fleet_command(other)
    end
  end

  defp fleet_command(line) do
    case line do
      "/fleet" -> :fleet
      "/spawn " <> rest -> spawn_command(rest)
      "/move " <> rest -> move_command(rest)
      "/connect " <> name -> {:connect, String.trim(name)}
      "/kill " <> target -> {:kill, String.trim(target)}
      other -> decision(other)
    end
  end

  # An unrecognised slash is a question that happens to start with one.
  defp decision(line) do
    case line do
      slash when slash in ["/approve", "/y"] -> :approve
      slash when slash in ["/deny", "/n"] -> {:deny, nil}
      "/deny " <> reason -> {:deny, String.trim(reason)}
      "/n " <> reason -> {:deny, String.trim(reason)}
      text -> {:ask, text}
    end
  end

  defp spawn_command(rest) do
    {name, options, prompt} = arguments(rest)
    {:spawn, name, options, prompt}
  end

  defp move_command(rest) do
    {name, options, _prompt} = arguments(rest)
    {:move, name, options}
  end

  # A name, then `key=value` words as options; the first word without `=`
  # starts the free text.
  defp arguments(rest) do
    [name | words] = String.split(rest)
    {options, text} = Enum.split_while(words, &String.contains?(&1, "="))

    {name, Map.new(options, &option/1), presence(Enum.join(text, " "))}
  end

  defp option(word), do: word |> String.split("=", parts: 2) |> List.to_tuple()

  defp presence(""), do: nil
  defp presence(text), do: text

  defp answer(text, false), do: {:ask, text}

  defp answer(text, true) do
    case String.split(text, " ", parts: 2) do
      [word] -> bare(word, nil, text)
      [word, rest] -> bare(word, String.trim(rest), text)
    end
  end

  defp bare(word, rest, text) do
    case {String.downcase(word), rest} do
      {yes, nil} when yes in ["y", "yes"] -> :approve
      {no, rest} when no in ["n", "no"] -> {:deny, rest}
      _other -> {:ask, text}
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
      {"^y", "Approve", &__MODULE__.approve/2},
      {"^n", "Deny", &__MODULE__.deny/2},
      {"^t", "Trace", &__MODULE__.toggle_trace/2},
      {"^f", "Fleet", &__MODULE__.focus_fleet/2},
      {"^d", "Quit", &__MODULE__.quit/2}
    ]
  end

  @doc false
  def stop_turn(_event, term), do: {:noreply, interrupt(term)}

  @doc false
  def approve(_event, term), do: {:noreply, decide(term, :approve)}

  @doc false
  def deny(_event, term), do: {:noreply, decide(term, {:deny, @default_denial})}

  @doc false
  def toggle_trace(_event, term),
    do: {:noreply, assign(term, verbose?: not term.assigns.verbose?)}

  # Focuses the panel, showing it first if it is away. From the panel, puts it
  # away and returns to the prompt.
  @doc false
  def focus_fleet(_event, %{focused: "fleet"} = term),
    do: {:noreply, term |> assign(sidebar?: false) |> focus("prompt")}

  def focus_fleet(_event, term),
    do: {:noreply, term |> assign(sidebar?: true) |> refresh_fleet() |> focus("fleet")}

  @doc false
  def connect_highlighted(_event, term) do
    {:noreply, term |> connect_key(term.assigns.highlighted) |> focus("prompt")}
  end

  @doc false
  def quit(_event, term), do: {:stop, term}

  @impl Breeze.View
  def mount(opts, term) do
    agent = Keyword.fetch!(opts, :agent)
    model = Keyword.get(opts, :model, "")

    # Breeze applies a block's attribute defaults only when the module that
    # defines it is already loaded when the template first renders.
    {:module, Breeze.Blocks} = Code.ensure_loaded(Breeze.Blocks)
    :ok = Fleet.watch()

    term =
      term
      |> assign(
        spawn_opts: Keyword.get(opts, :spawn_opts, []),
        fleet: Fleet.list(),
        fleet_due?: false,
        sidebar?: Keyword.get(opts, :sidebar, true),
        model: model,
        verbose?: Keyword.get(opts, :verbose, false),
        usage: Usage.new(model),
        frame: 0,
        frame_due?: false,
        started_at: nil,
        draft: ""
      )
      |> attach(agent, Keyword.get(opts, :agent_id, agent))
      |> append_lines(banner())
      |> put_focus_keybindings("fleet", [{"Enter", "Connect", &__MODULE__.connect_highlighted/2}])
      |> focus("prompt")

    {:ok, term}
  end

  # Subscribes to `agent`'s events, and starts the transcript over with its
  # conversation and what it is doing now. `agent_id` is what the events are
  # published under.
  defp attach(term, agent, agent_id) do
    # `:raw` delivers `{:tool_call, chunk}` with its arguments.
    :ok = Event.Bus.subscribe(agent_id, level: :raw)
    %{state: state, pending: pending} = Agent.status(agent)
    parked = Agent.parked(agent)

    term
    |> assign(
      agent: agent,
      agent_id: agent_id,
      highlighted: agent_id,
      transcript: Transcript.new(width(term)),
      activity: Activity.new(),
      answer: Markdown.new(),
      reasoning: Markdown.new(),
      thinking: "",
      running?: state == :running,
      parked: parked,
      queued: pending,
      chars: 0,
      answering?: false
    )
    |> playback(Agent.get_context(agent))
    |> parked_notice(parked)
  end

  # The conversation so far, as the transcript would have shown it: what the
  # person asked, and what the agent answered. Tool exchanges are left out.
  defp playback(term, %ReqLLM.Context{messages: messages}) do
    Enum.reduce(messages, term, &play/2)
  end

  defp play(%{role: :user} = message, term), do: question(term, LLM.Context.text(message))

  defp play(%{role: :assistant} = message, term) do
    {streamed, answer} = Markdown.push(Markdown.new(), LLM.Context.text(message))
    {rest, _answer} = Markdown.flush(answer)

    term |> assign(answering?: false) |> answer_lines(streamed ++ rest)
  end

  defp play(_tool_message, term), do: term

  defp parked_notice(term, []), do: term
  defp parked_notice(term, calls), do: append(term, View.parked(calls))

  defp question(term, text), do: append_lines(term, ["", View.question(text)])

  defp banner,
    do: [Text.tag("Enter sends · Esc stops · Ctrl-D quits · /help for the rest", @faint)]

  # -- render ----------------------------------------------------------------

  @impl Breeze.View
  def render(assigns) do
    width = assigns.breeze.terminal.width
    height = assigns.breeze.terminal.height

    if wrap_width(width - sidebar_width(assigns, width)) != assigns.transcript.width do
      send(self(), {:rewrap, wrap_width(width - sidebar_width(assigns, width))})
    end

    prompt_height = prompt_rows(assigns.draft, width) + 2
    log_height = max(height - @chrome_rows - prompt_height, 1)
    side_width = sidebar_width(assigns, width)

    assigns =
      assign(assigns,
        source: Transcript.source(assigns.transcript),
        log_height: log_height,
        log_class: log_class(width - side_width, log_height),
        side_width: side_width,
        fleet_rows: fleet_rows(assigns, side_width),
        prompt_class:
          "block w-full h-#{prompt_height} bg-none border-surface focus:border-primary",
        header: header(assigns),
        status: status(assigns, width),
        meta: meta(assigns, width)
      )

    ~H"""
    <box id="app" focus-scope="trap" class="block w-screen h-screen overflow-hidden">
      <box class="block w-full h-1 overflow-hidden">{@header}</box>
      <box class={"inline w-full overflow-hidden h-#{@log_height}"}>
        <box
          id="log"
          focusable
          implicit={TarsTUI.Scroll}
          scroll-autoscroll="bottom"
          class={@log_class}
        >
          {@source}
        </box>
        <box
          :if={@side_width > 0}
          class={"block overflow-hidden padding-left-1 w-#{@side_width} h-#{@log_height}"}
        >
          <box class="block w-full h-1 overflow-hidden">
            {TarsTUI.Fleet.heading(@fleet, @side_width)}
          </box>
          <box class={"block w-full h-#{@log_height - 1} overflow-hidden "}>
            <.list
              id="fleet"
              br-change="highlight"
              list-selected={@highlighted}
              selected-indicator=" "
              class="height-full scrollbar-mute-100"
              item_class="selected:bg-surface selected:text-muted"
            >
              <:item :for={{key, row} <- @fleet_rows} value={key}>{row}</:item>
            </.list>
          </box>
        </box>
      </box>
      <box class="block w-full h-1 overflow-hidden">{@status}</box>
      <.textarea
        id="prompt"
        br-change="draft"
        br-submit="ask"
        textarea-value={@draft}
        textarea-placeholder="Ask anything · /help"
        textarea-prefix="› "
        textarea-submit-on-enter={true}
        class={@prompt_class}
      />
      <box class="block w-full h-1 overflow-hidden">{@meta}</box>
    </box>
    """
  end

  defp log_class(width, height) do
    "inline overflow-scroll scrollbar-mute-100 w-#{width} h-#{height} " <>
      "border-b border-surface focus:border-primary"
  end

  # One list item per agent, as `{key, row}`, clipped to the space inside the
  # panel's gutter, the list's border and its selection column.
  defp fleet_rows(_assigns, 0), do: []

  defp fleet_rows(assigns, side_width) do
    Enum.map(assigns.fleet, &{&1.key, TarsTUI.Fleet.row(&1, assigns.agent_id, side_width - 4)})
  end

  # The panel takes what its rows need, and is dropped rather than squeezed on
  # a narrow terminal.
  defp sidebar_width(%{sidebar?: false}, _width), do: 0

  defp sidebar_width(assigns, width) do
    side = TarsTUI.Fleet.width(assigns.fleet)
    if width - side >= @min_log_width, do: side, else: 0
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

  defp status(%{running?: false, parked: [_ | _] = parked}, width) do
    names = Enum.map_join(parked, ", ", fn {call, _prompt} -> call.name end)
    left = Text.tag(" ? waiting on #{names} · y approve · n deny", [:bright, :yellow])
    right = Text.tag("Esc abandon · Ctrl-T trace · Ctrl-D quit ", @faint)
    Render.line(Render.justify(left, right, width))
  end

  defp status(%{running?: false}, width) do
    left = Text.tag(" idle · type a prompt and press Enter", @faint)
    right = Text.tag("Esc stop · Ctrl-T trace · Ctrl-F fleet · Ctrl-D quit ", @faint)
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

  def handle_event("highlight", %{value: key}, term),
    do: {:noreply, assign(term, highlighted: key)}

  def handle_event("ask", %{value: value}, term) do
    term = term |> assign(draft: "") |> reset("prompt")

    case command(value, term.assigns.parked != []) do
      :quit -> {:stop, term}
      command -> {:noreply, apply_command(command, term)}
    end
  end

  def handle_event(_name, _event, term), do: {:noreply, term}

  defp apply_command(:blank, term), do: term
  defp apply_command(:stop, term), do: interrupt(term)
  defp apply_command(:approve, term), do: decide(term, :approve)
  defp apply_command(:fleet, term), do: list_fleet(term)
  defp apply_command(:help, term), do: append_lines(term, [""] ++ View.help())
  defp apply_command({:deny, reason}, term), do: decide(term, {:deny, reason || @default_denial})

  defp apply_command({:spawn, name, options, prompt}, term),
    do: spawn_agent(term, name, options, prompt)

  defp apply_command({:move, name, options}, term), do: move_agent(term, name, options)
  defp apply_command({:connect, name}, term), do: connect(term, name)
  defp apply_command({:kill, prefix}, term), do: kill(term, prefix)
  defp apply_command({:ask, text}, term), do: ask(term, text)

  defp list_fleet(term) do
    term
    |> refresh_fleet()
    |> append_lines([""] ++ TarsTUI.Fleet.listing(Fleet.list()))
  end

  defp spawn_agent(term, name, options, prompt) do
    key = key(term, name)

    with {:ok, placement} <- placement(options),
         {:ok, pid} <- Fleet.spawn(key, term.assigns.spawn_opts ++ placement) do
      term |> switch(pid, key) |> append(View.spawned(key)) |> ask_if(prompt)
    else
      {:error, reason} -> append(term, View.error(reason))
    end
  end

  defp ask_if(term, nil), do: term
  defp ask_if(term, prompt), do: ask(term, prompt)

  defp move_agent(term, name, options) do
    key = key(term, name)

    with {:ok, [node: node]} <- placement(options),
         {:ok, _pid} <- Fleet.move(key, node) do
      term |> refresh_fleet() |> append(View.moved(key, node))
    else
      {:ok, []} -> append(term, View.error(:node_required))
      {:error, reason} -> append(term, View.error(reason))
    end
  end

  defp placement(%{"node" => name} = options) when map_size(options) == 1 do
    case node_named(name) do
      nil -> {:error, {:no_such_node, name}}
      node -> {:ok, [node: node]}
    end
  end

  defp placement(options) when map_size(options) == 0, do: {:ok, []}
  defp placement(options), do: {:error, {:unknown_options, Map.keys(options) -- ["node"]}}

  # A node by its full name, or by the part before the `@`.
  defp node_named(name) do
    Enum.find([node() | Node.list()], fn node ->
      Atom.to_string(node) in [name, "#{name}@#{host(node)}"]
    end)
  end

  defp host(node), do: node |> Atom.to_string() |> String.split("@", parts: 2) |> List.last()

  defp connect(term, name), do: connect_key(term, key(term, name))

  defp connect_key(term, key) do
    case Fleet.whereis(key) do
      nil ->
        append(term, View.no_such_agent(key))

      pid ->
        term |> switch(pid, key) |> append(View.connected(key))
    end
  end

  # Leaves the agent this client is attached to for `pid`, registered under
  # `key`. The agent is addressed by pid from here on: the registry is
  # eventually consistent, so a key may not yet resolve on this node for an
  # agent that just started on another.
  defp switch(term, pid, key) do
    Event.Bus.unsubscribe(term.assigns.agent_id)

    term |> attach(pid, key) |> refresh_fleet()
  end

  # Agents this client names live beside its own, under the same org and user.
  defp key(term, name), do: Fleet.key(name, term.assigns.spawn_opts)

  # A prefix ends in `/`; anything else names an agent under this client's org
  # and user. The agent this client is attached to is never removed.
  defp kill(term, target) do
    attached = term.assigns.agent_id

    cond do
      String.ends_with?(target, "/") and String.starts_with?(attached, target) ->
        append(term, View.attached(attached))

      String.ends_with?(target, "/") ->
        term |> refresh_fleet() |> append(View.forgotten(target, Fleet.forget_under(target)))

      key(term, target) == attached ->
        append(term, View.attached(attached))

      true ->
        forget(term, key(term, target))
    end
  end

  defp forget(term, key) do
    with pid when is_pid(pid) <- Fleet.whereis(key),
         :ok <- Fleet.forget(key) do
      term |> refresh_fleet() |> append(View.forgotten(key))
    else
      nil -> append(term, View.no_such_agent(key))
      {:error, reason} -> append(term, View.error(reason))
    end
  end

  # Every parked call takes the same answer. One question at a time is what a
  # terminal can ask clearly; a surface that needs them separately has
  # `Tars.Agent.resume/2`, which takes a decision per call.
  defp decide(%{assigns: %{parked: []}} = term, _decision),
    do: append(term, View.nothing_to_answer())

  defp decide(term, decision) do
    calls = term.assigns.parked
    :ok = Agent.resume(term.assigns.agent, decisions(calls, decision))

    term
    |> assign(parked: [])
    |> append(View.decided(calls, decision))
  end

  defp decisions(calls, decision),
    do: Map.new(calls, fn {call, _prompt} -> {call.id, decision} end)

  defp ask(term, text) do
    :ok = Agent.ask(term.assigns.agent, text)

    if term.assigns.running? do
      term
      |> assign(queued: term.assigns.queued + 1)
      |> append_lines([
        "",
        [View.prompt("»"), Text.tag(text, :bright), Text.tag("  · queued", @faint)]
      ])
    else
      question(term, text)
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

  # A group event says something in the fleet changed; the refresh behind it
  # reads the whole list once, however many events arrived.
  def handle_info({:group, _events, _info}, term) do
    if term.assigns.fleet_due? do
      {:noreply, term, invalidate: false}
    else
      Process.send_after(self(), :refresh_fleet, @fleet_after)
      {:noreply, assign(term, fleet_due?: true), invalidate: false}
    end
  end

  def handle_info(:refresh_fleet, term), do: {:noreply, refresh_fleet(term)}

  def handle_info(:tick, %{assigns: %{running?: true}} = term) do
    schedule_tick()
    {:noreply, assign(term, frame: term.assigns.frame + 1)}
  end

  def handle_info(:tick, term), do: {:noreply, term}

  def handle_info({:rewrap, width}, term) do
    {:noreply, assign(term, transcript: Transcript.rewrap(term.assigns.transcript, width))}
  end

  def handle_info(_message, term), do: {:noreply, term}

  defp refresh_fleet(term), do: assign(term, fleet: Fleet.list(), fleet_due?: false)

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
    |> assign(running?: true, parked: [], frame: 0, started_at: now(), queued: 0)
    |> trace(event)
  end

  defp handle(%Event{payload: {:turn_finished, _messages}} = event, term) do
    term |> settle() |> trace(event) |> assign(running?: false, parked: [])
  end

  defp handle(%Event{payload: {:turn_interrupted, stats}} = event, term) do
    term
    |> settle()
    |> trace(event)
    |> append(View.interrupted(stats))
    |> assign(running?: false, parked: [])
  end

  defp handle(%Event{payload: {:turn_parked, calls}} = event, term) do
    term
    |> settle()
    |> trace(event)
    |> append(View.parked(calls))
    |> assign(running?: false, parked: calls)
  end

  defp handle(%Event{payload: {:turn_failed, reason}} = event, term) do
    term
    |> settle()
    |> trace(event)
    |> append(View.error(reason))
    |> assign(running?: false, parked: [])
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
