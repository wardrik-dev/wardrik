defmodule WardrikTUI.App do
  @moduledoc """
  Terminal session coordinator.

  Owns Breeze callbacks, global key routing, screen layout, and redraw decisions.
  Components render the panes; App.Conversation projects agent events into display
  state; App.Connection owns subscriptions and saved views; App.Commands executes
  parsed commands. Prompt and Interaction adapt user actions to Breeze's widgets.

  User-facing behavior and shortcuts are documented in `docs/tui.md`.
  """
  use Breeze.View
  import Breeze.Blocks
  import WardrikTUI.Components.Chrome, only: [header: 1, status: 1, meta: 1]
  import WardrikTUI.Components.FleetPanel, only: [fleet: 1]
  import WardrikTUI.Components.Inspector, only: [inspector: 1]
  import WardrikTUI.Components.Palette, only: [palette_box: 1]

  alias Wardrik.Delegation
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias WardrikConsole.Filter
  alias WardrikTUI.App.Commands
  alias WardrikTUI.App.Connection
  alias WardrikTUI.App.Display
  alias WardrikTUI.App.Frames
  alias WardrikTUI.App.Interaction
  alias WardrikTUI.App.PaletteFlow
  alias WardrikTUI.App.Prompt
  alias WardrikTUI.App.TermState
  alias WardrikTUI.Components.Chrome
  alias WardrikTUI.History
  alias WardrikTUI.Palette
  alias WardrikTUI.Search
  alias WardrikTUI.Text
  alias WardrikTUI.Transcript
  alias WardrikTUI.View
  @frame_after 50
  @frame_after_most 400
  @sidebar_width 30
  @fleet_after 200
  @min_log_width 40
  @chrome_rows 3
  @max_prompt_rows 8
  @faint [:faint, :light_black]
  @default_denial "Denied by the person watching."
  @leader_after 1_500

  @doc """
  What `:options` answers for an agent this app starts under `key`: the
  options to spawn it with ahead of `:spawn_opts`, or why it cannot start.
  Without `:options`, none.
  """
  @spec options({module(), atom(), list()} | nil, String.t()) ::
          {:ok, keyword()} | {:error, String.t()}
  def options(nil, _key), do: {:ok, []}
  def options({module, function, args}, key), do: apply(module, function, [key | args])

  @doc "The fleet panel's width in columns, unless started with `:sidebar_width`."
  @spec default_sidebar_width() :: pos_integer()
  def default_sidebar_width, do: @sidebar_width

  # A frame's compositor cells are a large, short-lived allocation. The view
  # process starts with room for them, rather than growing its heap on the way
  # through each one.
  @view_heap_words 2_000_000

  @doc """
  What `Breeze.Server` runs this app with, `start_opts` being what `mount/2`
  is given. The terminal launcher and every SSH session run it the same way.
  """
  @spec server_opts(keyword()) :: keyword()
  def server_opts(start_opts) do
    [
      view: __MODULE__,
      start_opts: start_opts,
      global_keybindings: keybindings(),
      mouse: true,
      logger: false,
      inspector: false,
      internal: [child_process_flags: [min_heap_size: @view_heap_words]]
    ]
  end

  @doc """
  Keybindings that work wherever focus is. Pass them as `:global_keybindings`
  when starting the session.

  `Ctrl-X` is the leader: the next `h`, `j`, `k` or `l` moves focus between
  the transcript, the fleet panel and the prompt, `s` stops the turn, and
  `Esc` cancels. `i` in the transcript or the panel focuses the prompt. `Up`
  and `Down` at the prompt's first and last line recall earlier lines, and
  `Ctrl-G` edits the draft in `$VISUAL` or `$EDITOR`. `Ctrl-P` opens and
  closes the command palette. `Ctrl-C` never reaches these: Breeze leaves on
  it.
  """
  @spec keybindings() :: [{String.t(), String.t(), (map(), Breeze.Term.t() -> term())}]
  def keybindings do
    [
      {"^x", "Leader", &__MODULE__.leader/2},
      {"Escape", "Back", &__MODULE__.back/2},
      {"i", "Prompt", &__MODULE__.to_prompt/2},
      {"ArrowUp", "Older", &Prompt.older/2},
      {"ArrowDown", "Newer", &Prompt.newer/2},
      {"^g", "Edit", &Prompt.edit/2},
      {"^p", "Palette", &__MODULE__.palette/2},
      {"^y", "Approve", &__MODULE__.approve/2},
      {"^n", "Deny", &__MODULE__.deny/2},
      {"^t", "Trace", &__MODULE__.toggle_trace/2},
      {"^f", "Fleet", &__MODULE__.toggle_fleet/2},
      {"^d", "Quit", &__MODULE__.quit/2},
      {"/", "Search", &__MODULE__.search/2},
      {"n", "Next match", &__MODULE__.next_match/2},
      {"N", "Previous match", &__MODULE__.previous_match/2},
      {"t", "Tools", &__MODULE__.tools/2},
      {"y", "Copy", &__MODULE__.copy/2}
    ]
  end

  @doc false
  def approve(_event, term), do: {:noreply, Commands.decide(term, nil, :approve)}

  # In the transcript, `/` searches it, `n` and `N` step through the matches,
  # `t` picks a tool call to see in full and `y` copies the answer. Anywhere
  # else the letters are typed.
  @doc false
  def search(_event, %{focused: "log"} = term), do: {:noreply, Interaction.open_search(term, "")}

  def search(_event, _term), do: :continue

  @doc false
  def next_match(_event, %{focused: "log"} = term),
    do: {:noreply, Interaction.step_match(term, :next)}

  def next_match(_event, _term), do: :continue

  @doc false
  def previous_match(_event, %{focused: "log"} = term),
    do: {:noreply, Interaction.step_match(term, :previous)}

  def previous_match(_event, _term), do: :continue

  @doc false
  def tools(_event, %{focused: "log"} = term), do: {:noreply, Interaction.open_tools(term)}

  def tools(_event, _term), do: :continue

  @doc false
  def copy(_event, %{focused: "log"} = term), do: {:noreply, Interaction.copy_text(term, :answer)}

  def copy(_event, _term), do: :continue

  @doc false
  def deny(_event, term), do: {:noreply, Commands.decide(term, nil, {:deny, @default_denial})}

  @doc false
  def toggle_trace(_event, term),
    do: {:noreply, assign(term, verbose?: not term.assigns.verbose?)}

  # Shows or hides the panel. Hiding it while it is focused returns to the
  # prompt. On a terminal too narrow for the panel beside the transcript, it
  # is brought up over the panes and put away instead.
  @doc false
  def toggle_fleet(_event, %{assigns: %{sidebar?: true}} = term) do
    cond do
      narrow?(term) and term.focused == "fleet" ->
        {:noreply, Interaction.focus_pane(term, "prompt")}

      narrow?(term) ->
        {:noreply, Interaction.focus_pane(term, "fleet")}

      term.focused == "fleet" ->
        {:noreply, term |> assign(sidebar?: false) |> Interaction.focus_pane("prompt")}

      true ->
        {:noreply, term |> assign(sidebar?: false) |> Interaction.sync_pane()}
    end
  end

  def toggle_fleet(_event, term),
    do:
      {:noreply,
       term |> assign(sidebar?: true) |> Connection.refresh_fleet() |> Interaction.sync_pane()}

  # Whether the panel has no room beside the transcript.
  defp narrow?(%{assigns: %{sidebar_width: side}} = term),
    do: terminal_width(term) - side < @min_log_width

  defp terminal_width(%{terminal: %{size: %{width: width}}}) when is_integer(width), do: width

  defp terminal_width(_term), do: 100

  # A letter goes to the focused pane before any binding sees it, so while the
  # leader waits the prompt is focused and the letter arrives as a change to
  # the draft, where `direction/2` reads it back out. The pane the leader was
  # pressed in is remembered, for the moves and for cancelling.
  @doc false
  def leader(_event, %{assigns: %{palette: %{}}} = term), do: {:noreply, term}

  def leader(_event, term) do
    ref = make_ref()
    Process.send_after(self(), {:leader_timeout, ref}, @leader_after)
    origin = term.focused || "prompt"

    {:noreply, term |> assign(leader: {ref, origin}, pane: origin) |> focus("prompt")}
  end

  @doc false
  def to_prompt(_event, %{assigns: %{inspecting: {_kind, _what, _where}}} = term),
    do: {:noreply, term |> Interaction.close_inspector() |> Interaction.focus_pane("prompt")}

  def to_prompt(_event, %{focused: focused} = term) when focused in ["log", "fleet"],
    do: {:noreply, Interaction.focus_pane(term, "prompt")}

  def to_prompt(_event, _term), do: :continue

  # Cancels a pending leader, or returns to the prompt from another pane. In
  # the prompt, with nothing else to dismiss, it stops the turn, or abandons a
  # parked one; idle, it does nothing.
  @doc false
  def back(_event, %{assigns: %{palette: %{}}} = term),
    do: {:noreply, Interaction.close_palette(term)}

  def back(_event, %{assigns: %{inspecting: {_kind, _what, _where}}} = term),
    do: {:noreply, Interaction.close_inspector(term)}

  def back(_event, %{assigns: %{leader: {_ref, _origin}}} = term), do: {:noreply, unlead(term)}

  def back(_event, %{focused: "prompt"} = term) do
    term = Interaction.sync_pane(term)
    if busy?(term), do: {:noreply, Commands.interrupt(term)}, else: {:noreply, term}
  end

  def back(_event, term), do: {:noreply, Interaction.focus_pane(term, "prompt")}

  defp busy?(%{assigns: %{running?: running?, parked: parked}}), do: running? or parked != []

  # -- the palette -----------------------------------------------------------

  # Opens the palette over the panes, remembering where focus came from, or
  # closes it.
  @doc false
  def palette(_event, %{assigns: %{palette: nil}} = term) do
    palette = %Palette{step: :commands, origin: term.focused || "prompt"}
    {:noreply, term |> Connection.refresh_fleet() |> Interaction.open_palette(palette)}
  end

  def palette(_event, term), do: {:noreply, Interaction.close_palette(term)}

  defp choose(term, palette, choice) do
    palette |> PaletteFlow.select(choice, term.assigns.parked) |> palette_action(term)
  end

  defp palette_action(:ignore, term), do: {:noreply, term}

  defp palette_action({:step, step, command, chosen}, term),
    do: {:noreply, Interaction.step_palette(term, step, command, chosen)}

  defp palette_action({:run, command, line}, term) do
    recent = Enum.take([command.name | List.delete(term.assigns.recent, command.name)], 5)
    term |> assign(recent: recent) |> Interaction.close_palette() |> Commands.run_line(line)
  end

  defp palette_action({:search, query, row}, term) do
    search = Search.new(query, term.assigns.transcript, row)
    count = length(Search.rows(term.assigns.transcript, query))

    {:noreply,
     term
     |> Interaction.close_palette()
     |> assign(search: search)
     |> Interaction.go_to_row(row)
     |> Interaction.flash(View.match(query, search.at + 1, count))}
  end

  defp palette_action({:inspect_tool, index, origin}, term),
    do: {:noreply, term |> Interaction.close_palette() |> Interaction.inspect_tool(index, origin)}

  # Enter in the panel: on an agent, connects; on a delegation, inspects it.
  @doc false
  def connect_highlighted(_event, term) do
    case String.split(term.assigns.highlighted || "", "\t", parts: 2) do
      [key, span_id] -> {:noreply, Interaction.inspect_delegation(term, key, span_id)}
      [key] -> {:noreply, term |> Connection.connect_key(key) |> Interaction.focus_pane("prompt")}
    end
  end

  # Whether the frame should keep ticking: for the elapsed times of delegations
  # still going under an expanded agent. The running turn's own count is drawn
  # by `WardrikTUI.Elapsed` and needs no frame.
  defp ticking?(%{assigns: %{expanded: expanded}}) do
    Enum.any?(expanded, fn
      {_key, %Delegation{} = delegations} -> Delegation.summary(delegations).active > 0
      {_key, nil} -> false
    end)
  end

  # Leaves from the prompt with nothing typed. In the transcript the same key
  # scrolls half a page; anywhere else it does nothing.
  @doc false
  def quit(_event, %{focused: "log"}), do: :continue

  def quit(_event, %{focused: "prompt", assigns: %{draft: ""}} = term), do: {:stop, term}

  def quit(_event, term), do: {:noreply, Interaction.sync_pane(term)}

  # The transcript sits above the prompt and left of the panel.
  defp neighbour("prompt", key, _fleet?) when key in ["k", "h"], do: "log"

  defp neighbour("prompt", "l", true), do: "fleet"

  defp neighbour("prompt", "l", false), do: "log"

  defp neighbour("log", "l", true), do: "fleet"

  defp neighbour("log", "j", _fleet?), do: "prompt"

  defp neighbour("fleet", "h", _fleet?), do: "log"

  defp neighbour("fleet", "j", _fleet?), do: "prompt"

  defp neighbour(pane, _key, _fleet?), do: pane

  # Drops a pending leader and puts focus back where it came from.
  defp unlead(%{assigns: %{leader: {_ref, origin}}} = term),
    do: term |> assign(leader: nil) |> Interaction.focus_pane(origin)

  # The one letter the leader was followed by, taken back out of the draft
  # and acted on: a direction moves focus, `i` is the prompt, `s` stops the
  # turn. Anything else ends the wait and stays typed.
  defp direction(%{assigns: %{leader: {_ref, origin}, draft: previous}} = term, value) do
    case inserted(previous, value) do
      {letter, at} when letter in ["h", "j", "k", "l", "i", "s"] ->
        term
        |> assign(leader: nil, draft: previous)
        |> update_implicit("prompt", fn {_module, state} ->
          %{state | value: previous, cursor: at}
        end)
        |> led(letter, origin)

      _other ->
        assign(term, leader: nil, draft: value, pane: "prompt")
    end
  end

  defp led(term, "i", _origin), do: Interaction.focus_pane(term, "prompt")

  defp led(term, "s", origin) do
    term = Interaction.focus_pane(term, origin)
    if busy?(term), do: Commands.interrupt(term), else: term
  end

  defp led(term, key, origin),
    do: Interaction.focus_pane(term, neighbour(origin, key, term.assigns.sidebar?))

  # The grapheme `value` has that `previous` lacks, and where, when that is
  # the only difference.
  defp inserted(previous, value) do
    before = String.graphemes(previous)
    after_ = String.graphemes(value)

    with true <- length(after_) == length(before) + 1,
         at when is_integer(at) <-
           Enum.find_index(Enum.zip(before ++ [nil], after_), fn {a, b} -> a != b end),
         true <- List.delete_at(after_, at) == before do
      {Enum.at(after_, at), at}
    else
      _other -> nil
    end
  end

  # Who decides from a TUI started in a terminal here: the account running it.
  defp terminal, do: %Wardrik.Principal{type: :terminal, id: System.get_env("USER") || "unknown"}

  @impl Breeze.View
  def mount(opts, term) do
    agent = Keyword.fetch!(opts, :agent)

    # Breeze applies a block's attribute defaults only when the module that
    # defines it is already loaded when the template first renders.
    Enum.each(
      [
        Breeze.Blocks,
        WardrikTUI.Components.Chrome,
        WardrikTUI.Components.FleetPanel,
        WardrikTUI.Components.Inspector,
        WardrikTUI.Components.Palette
      ],
      &Code.ensure_loaded!/1
    )

    :ok = Fleet.watch()

    term =
      term
      |> assign(
        spawn_opts: Keyword.get(opts, :spawn_opts, []),
        options: Keyword.get(opts, :options),
        principal: Keyword.get_lazy(opts, :principal, &terminal/0),
        fleet: [],
        fleet_due?: false,
        sidebar?: Keyword.get(opts, :sidebar, true),
        sidebar_width: Keyword.get(opts, :sidebar_width, @sidebar_width),
        unseen: %{},
        filter: Filter.none(),
        model: Keyword.get(opts, :model, ""),
        verbose?: Keyword.get(opts, :verbose, false),
        editor: Keyword.get(opts, :editor, &WardrikTUI.Editor.edit/2),
        clipboard: Keyword.get(opts, :clipboard, &WardrikTUI.Clipboard.copy/1),
        notice: nil,
        tools: [],
        answer_text: "",
        tail: [],
        search: nil,
        views: %{},
        available?: true,
        confirm: nil,
        pane: "prompt",
        leader: nil,
        palette: nil,
        choices: [],
        recent: [],
        expanded: %{},
        collapsed: MapSet.new(),
        inspecting: nil,
        delegations: Delegation.new(),
        editing: nil,
        walking: nil,
        commands: History.new(),
        history: History.new(),
        frame_due?: false,
        frame_after: @frame_after,
        frame_at: nil,
        tick_due?: false,
        started_at: nil,
        draft: ""
      )
      |> Connection.attach(agent, Keyword.get(opts, :agent_id, agent))
      |> Connection.refresh_fleet()
      |> Display.append_lines(banner())
      |> put_focus_keybindings("fleet", [{"Enter", "Connect", &__MODULE__.connect_highlighted/2}])
      |> Interaction.focus_pane("prompt")

    {:ok, term}
  end

  defp banner,
    do: [
      Text.tag(
        "Enter sends · Esc stops · Ctrl-X then h/j/k/l moves · /help for the rest",
        @faint
      )
    ]

  @impl Breeze.View
  def render(assigns) do
    width = assigns.breeze.terminal.width
    height = assigns.breeze.terminal.height

    if TermState.wrap_width(width - sidebar_width(assigns, width)) != assigns.transcript.width do
      send(self(), {:rewrap, TermState.wrap_width(width - sidebar_width(assigns, width))})
    end

    prompt_height = prompt_rows(assigns.draft, width) + 2
    log_height = max(height - @chrome_rows - prompt_height, 1)
    side_width = sidebar_width(assigns, width)
    overlay? = assigns.sidebar? and side_width == 0 and assigns.pane == "fleet"
    panel_width = if overlay?, do: assigns.sidebar_width, else: side_width
    shown = Connection.shown(assigns)

    assigns =
      assign(assigns,
        width: width,
        height: height,
        shown: shown,
        panel_width: panel_width,
        status_state:
          Map.take(assigns, [
            :notice,
            :available?,
            :agent_id,
            :running?,
            :parked,
            :leader,
            :activity,
            :unread,
            :chars,
            :started_at,
            :thinking,
            :sidebar?,
            :palette,
            :editing,
            :pane
          ]),
        inspector_delegations: inspector_delegations(assigns),
        source: Transcript.source(assigns.transcript, assigns.tail),
        log_height: log_height,
        log_class: log_class(width - side_width, log_height),
        side_width: side_width,
        fleet_overlay?: overlay?,
        prompt_class:
          "block w-full h-#{prompt_height} bg-none border-surface focus:border-primary " <>
            "placeholder:text-8",
        placeholder: Chrome.placeholder(assigns)
      )

    ~H"""
    <box id="app" focus-scope="trap" class="block w-screen h-screen overflow-hidden">
      <.header model={@model} agent_id={@agent_id} verbose={@verbose?}/>
      <box class={"inline w-full overflow-hidden h-#{@log_height}"}>
        <box
          id="log"
          focusable
          br-change="scroll"
          implicit={WardrikTUI.Scroll}
          scroll-autoscroll="bottom"
          class={@log_class}
        >
          {@source}
        </box>
        <.fleet
          :if={@side_width > 0}
          fleet={@fleet}
          shown={@shown}
          agent_id={@agent_id}
          unseen={@unseen}
          filter={@filter}
          expanded={@expanded}
          delegations={@delegations}
          highlighted={@highlighted}
          width={@panel_width}
          height={@log_height}
          overlay={false}
        />
      </box>
      <.fleet
        :if={@fleet_overlay?}
        fleet={@fleet}
        shown={@shown}
        agent_id={@agent_id}
        unseen={@unseen}
        filter={@filter}
        expanded={@expanded}
        delegations={@delegations}
        highlighted={@highlighted}
        width={@panel_width}
        height={@height}
        overlay={true}
      />
      <.status state={@status_state} width={@width}/>
      <.textarea
        id="prompt"
        br-change="draft"
        br-submit="ask"
        textarea-value={@draft}
        textarea-placeholder={@placeholder}
        textarea-prefix="› "
        textarea-submit-on-enter={true}
        class={@prompt_class}
      />
      <.meta usage={@usage} queued={@queued} running={@running?} width={@width}/>
      <.inspector
        :if={@inspecting != nil}
        inspecting={@inspecting}
        tools={@tools}
        delegations={@inspector_delegations}
        width={@width}
        height={@height}
      />
      <.palette_box
        :if={@palette != nil}
        palette={@palette}
        choices={@choices}
        width={@width}
        height={@height}
      />
    </box>
    """
  end

  defp inspector_delegations(%{inspecting: {:delegation, key, _span}} = assigns),
    do: WardrikTUI.Fleet.expanded_delegations(assigns, key)

  defp inspector_delegations(_assigns), do: nil

  # The panel is as wide as it was configured, whatever its rows say, and is
  # left out beside the transcript on a terminal too narrow for both.
  defp sidebar_width(%{sidebar?: false}, _width), do: 0

  defp sidebar_width(%{sidebar_width: side}, width),
    do: if(width - side >= @min_log_width, do: side, else: 0)

  defp log_class(width, height) do
    "inline overflow-scroll scrollbar-mute-100 w-#{width} h-#{height} " <>
      "border-b border-surface focus:border-primary"
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

  @impl Breeze.View
  def handle_event("draft", %{value: value}, %{assigns: %{leader: {_ref, _origin}}} = term),
    do: {:noreply, direction(term, value)}

  def handle_event("draft", %{value: value}, term),
    do: {:noreply, term |> assign(draft: value, pane: "prompt") |> Prompt.leave()}

  def handle_event("highlight", %{value: key}, term),
    do: {:noreply, assign(term, highlighted: key, pane: "fleet")}

  def handle_event("scroll", %{pinned_bottom: pinned?}, term),
    do:
      {:noreply, assign(term, unread: if(pinned?, do: 0, else: term.assigns.unread), pane: "log")}

  def handle_event("ask", %{value: value}, term),
    do: term |> assign(draft: "", leader: nil) |> reset("prompt") |> Commands.run_line(value)

  def handle_event("palette", %{action: :close}, term),
    do: {:noreply, Interaction.close_palette(term)}

  def handle_event("palette", %{action: :back}, %{assigns: %{palette: %{step: step}}} = term)
      when step in [:commands, :help, :search, :tool],
      do: {:noreply, term}

  def handle_event("palette", %{action: :back}, term),
    do: {:noreply, Interaction.restart_palette(term)}

  def handle_event("palette", %{query: query, cursor: cursor}, term),
    do: {:noreply, Interaction.update_palette(term, &%{&1 | query: query, cursor: cursor})}

  def handle_event("palette_run", _event, %{assigns: %{palette: nil}} = term),
    do: {:noreply, term}

  def handle_event("palette_run", %{cursor: cursor}, %{assigns: %{palette: palette}} = term),
    do: choose(term, palette, Enum.at(term.assigns.choices, cursor))

  def handle_event(:input, %{"key" => "l"}, %{focused: "fleet"} = term) do
    key = Connection.agent_of(term.assigns.highlighted)
    collapsed = MapSet.delete(term.assigns.collapsed, key)
    {:noreply, term |> assign(collapsed: collapsed) |> Connection.expand(key)}
  end

  def handle_event(:input, %{"key" => "h"}, %{focused: "fleet"} = term),
    do: {:noreply, Connection.collapse(term, Connection.agent_of(term.assigns.highlighted))}

  def handle_event(:input, %{"key" => "n"}, %{focused: "fleet"} = term),
    do: {:noreply, Interaction.highlight_next(term)}

  def handle_event(:input, %{"key" => "a"}, %{focused: "fleet"} = term),
    do: {:noreply, Interaction.toggle_attention(term)}

  def handle_event(_name, _event, term), do: {:noreply, term}

  @impl Breeze.View
  def handle_info(%Event{source: %{agent_id: id}} = event, %{assigns: %{agent_id: id}} = term) do
    {:noreply, term |> Display.apply_event(event) |> Frames.frame_due(), invalidate: false}
  end

  # A lifecycle event from an agent expanded in the panel.
  def handle_info(%Event{source: %{agent_id: id}} = event, term) do
    case term.assigns.expanded do
      %{^id => %Delegation{} = delegations} ->
        expanded = Map.put(term.assigns.expanded, id, Delegation.fold(delegations, event))
        {:noreply, term |> assign(expanded: expanded) |> Frames.frame_due(), invalidate: false}

      _other ->
        {:noreply, term, invalidate: false}
    end
  end

  # The one redraw for everything but a key. A frame that arrives late says
  # the last redraw took longer than the interval, so the interval doubles;
  # one on time halves it back towards the base.
  def handle_info(:frame, term) do
    late =
      System.monotonic_time(:millisecond) -
        (term.assigns.frame_at || System.monotonic_time(:millisecond))

    frame_after =
      if late > div(term.assigns.frame_after, 2),
        do: min(term.assigns.frame_after * 2, @frame_after_most),
        else: max(div(term.assigns.frame_after, 2), @frame_after)

    {:noreply,
     term
     |> Interaction.sync_pane()
     |> PaletteFlow.refresh()
     |> assign(frame_due?: false, frame_after: frame_after)}
  end

  def handle_info({:notice_timeout, ref}, %{assigns: %{notice: {ref, _text}}} = term),
    do: {:noreply, assign(term, notice: nil)}

  def handle_info({:notice_timeout, _stale}, term), do: {:noreply, term, invalidate: false}

  def handle_info({:leader_timeout, ref}, %{assigns: %{leader: {ref, _origin}}} = term),
    do: {:noreply, unlead(term)}

  def handle_info({:leader_timeout, _stale}, term), do: {:noreply, term, invalidate: false}

  def handle_info({:edited, ref, result}, %{assigns: %{editing: {ref, agent_id, _pid}}} = term),
    do:
      {:noreply,
       term |> assign(editing: nil) |> Interaction.sync_pane() |> Prompt.edited(agent_id, result)}

  def handle_info({:edited, _stale, _result}, term), do: {:noreply, term, invalidate: false}

  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %{assigns: %{editing: {_edit, _id, pid}}} = term
      )
      when reason != :normal,
      do: {:noreply, term |> assign(editing: nil) |> Display.append(View.editor_failed(reason))}

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

  def handle_info(:refresh_fleet, term),
    do:
      {:noreply,
       term |> Interaction.sync_pane() |> Connection.refresh_fleet() |> Frames.frame_due(),
       invalidate: false}

  def handle_info(:tick, term) do
    term = assign(term, tick_due?: false)

    if ticking?(term) do
      term =
        term |> Frames.tick() |> Interaction.sync_pane()

      {:noreply, Frames.frame_due(term), invalidate: false}
    else
      {:noreply, term, invalidate: false}
    end
  end

  def handle_info({:rewrap, width}, term) do
    {:noreply, assign(term, transcript: Transcript.rewrap(term.assigns.transcript, width))}
  end

  def handle_info(_message, term), do: {:noreply, term}
end
