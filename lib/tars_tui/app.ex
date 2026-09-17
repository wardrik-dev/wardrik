defmodule TarsTUI.App do
  # Events are folded as they arrive; the frame is redrawn at most this often
  # while they do, and half as often each time a redraw falls behind, up to
  # the limit.
  @frame_after 50
  @frame_after_most 400
  # The fleet panel's width in columns, unless started with `:sidebar_width`.
  @sidebar_width 30

  @moduledoc """
  A full-screen terminal client for one agent.

  A `Tars.Event.Bus` subscriber holding no conversation state, so several can
  watch the same agent. Events are folded as they arrive, and the frame is
  redrawn at most every #{@frame_after} milliseconds while they do, less
  often when a redraw itself falls behind, so the frame rate follows neither
  the token rate nor the size of the terminal and keys are handled promptly.
  A key is drawn at once. Five rows, top to bottom:

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
       eight rows; a line entered while a turn runs steers it, asking it to
       stop at its next boundary and start again with the line appended, and
       is echoed as such; a line entered while a turn is parked queues behind
       the decision it waits for
    5. **meta**: tokens in and out, reasoning tokens, cost and requests on the
       left, counted for the attached agent while this client watches it;
       messages steering or queued behind the current turn on the right

  Only text on the turn's root span is rendered as prose. Text streamed by
  delegated work appears as the tree of spans and tool calls.

  ## The fleet

  A fleet panel down the right lists every agent in the cluster, what each is
  doing, and which node it is on. It is driven by `Tars.Fleet.watch/1` rather
  than polling. With the panel focused, `Up`, `Down`, `j` and `k` move
  through the agents and `Enter` connects to the one under the cursor.

  Under each agent the panel shows one row per delegation its current turn
  has started through `Tars.Subagent.run/3`, as a tree, each with how it is
  going and how long it has taken. The rows come from the agent's
  `Tars.Agent.snapshot/1` and then follow its `:lifecycle` events, which is
  the shape of its work without its token stream. `h` on an agent collapses
  its rows, and stays collapsed until `l` expands them again. `Enter` on a
  delegation opens an inspector over the panes: what it was asked, the work
  under it, and what it answered or why it failed; `Esc` closes it. An
  agent's row also counts its delegations, going and started, and says when
  its last turn failed.

  An agent needs attention when it is waiting on a person, or when it
  finished a turn while this client was watching another: its row is marked
  `!`, says `new result` or `failed`, and the heading counts them. `/next`
  connects to the next one after the attached agent, and connecting is what
  clears the mark. In the panel `n` moves to the next one and `a` shows only
  them. `/filter QUERY` narrows the panel by text, `name:`, `org:`, `user:`,
  `node:`, `status:` and `attention`, as `TarsTUI.Fleet.Filter` reads it,
  and `/filter` alone shows every agent again. Rows keep their order, by key,
  whatever changes. Two agents going by one name are both shown by their
  whole key.

  The panel is `#{@sidebar_width}` columns wide unless started with
  `:sidebar_width`, and does not change with its rows. On a terminal too
  narrow to hold it beside the transcript it is shown over the panes instead,
  while it is focused: `Ctrl-F`, `Tab` or `Ctrl-X` then `l` bring it up and
  `Esc` or `i` put it away.

  `/spawn NAME [node=NODE] [--bg] [-- prompt]` starts an agent with the same
  `:spawn_opts` this client's own agent was given, on the named node if one is
  given, attaches to it, and sends it the prompt; with `--bg` it stays here,
  and the prompt goes to the new agent where it is. A name already running is
  connected to rather than started again, and said to be. `/connect NAME`
  attaches to an agent already running, wherever it is: a name in this
  client's scope, a whole key, or part of one, which is completed when one
  agent holds it and offered as a choice when several do. `/connect` alone
  opens that choice. Attaching replays the conversation so far: what was
  asked, what was answered, and each tool call with what it returned.
  Attaching on start works the same way. `/fleet` shows the panel and moves
  into it.

  Each agent this client has watched keeps its transcript, scroll position,
  draft and usage, so connecting back restores the place it was left at, and
  messages that arrived meanwhile are replayed under a note. Events are only
  folded for the agent attached now, so a switch mid-stream leaves nothing of
  the previous agent behind.

  When the attached agent comes back under another process, after a move or a
  restart on another node, this client follows it and says so. While it is
  not running at all, the status row says so and nothing typed is sent.

  `/move NAME node=NODE` restarts an agent on another node with the state it
  had; without a node, or a name, it asks for them. An agent whose turn is
  running or waiting is not moved until `/confirm`, after what the move would
  interrupt has been shown. `/stop` interrupts this agent; `/stop NAME`
  another, and `/stop PREFIX/` every agent under a prefix. `/shutdown NAME`
  stops an agent and keeps its conversation for `/spawn` to bring back. `/rm
  NAME` and `/rm PREFIX/` delete agents and their conversations: the first
  shows exactly what would go, and `/confirm` does it. The agent this client
  is attached to is never removed.

  ## Inspecting the transcript

  In the transcript `/` searches it: the rows holding the text typed are
  listed over the panes, `Enter` scrolls to the one chosen, and `n` and `N`
  step through the matches after that. `/find TEXT` does the same from the
  prompt. `t`, or `/tools`, lists every tool call of the conversation, and
  `Enter` on one opens it in the inspector: its arguments and what it
  returned, in full. `y`, or `/copy`, puts the last answer on the clipboard
  through `TarsTUI.Clipboard`, and `/copy code` its last code block.

  While the transcript is scrolled up, output arriving below it is announced
  on the status row until `End` follows it again. Notices about the client
  itself, a filter applied, a search landed, text copied, show on the status
  row for a moment rather than in the transcript; what changes the fleet or
  the conversation is written to the transcript. The status row names the
  focused pane before its keys, so focus reads without colour.

  A slash word that is no command is reported with the commands it resembles,
  and nothing is sent; a command given the wrong thing shows its usage. Either
  way the line stays in the prompt to be corrected. A line starting with `//`
  is sent as typed, with one slash taken off. `/help` opens every key and
  command over the panes, the keys of the pane focus came from first, narrowed
  as letters are typed; `Enter` on a command runs it and `Esc` closes.

  ## Approvals

  A parked turn shows each call it is waiting on, numbered. With one call,
  `y` and `n` answer it. With several, `/approve N` and `/deny N reason` answer
  one, and `/approve all` answers every one at once; a bare `y` or `n` asks
  which. Calls left unanswered stay parked.

  ## Keys

  The focused pane shows it in the primary colour: the prompt's box, the
  fleet panel's border, or the rule under the transcript. The status row
  names the keys that matter in the focused pane.

  `Tab` and `Shift-Tab` cycle the prompt, the transcript and the panel.
  `Ctrl-X` is the leader: followed by `h`, `j`, `k` or `l` it moves focus in
  that direction, with the transcript above the prompt and left of the panel,
  and the status row shows the moves while it waits. `Esc` returns to the
  prompt from either other pane and cancels a pending leader; in the prompt it
  does nothing. `i` in the transcript or the panel focuses the prompt.

  `Enter` sends. `Up` on the prompt's first line and `Down` on its last walk
  what was entered before: with the draft starting with `/`, the commands
  typed in this client, whichever agent was attached; otherwise the prompts
  sent to the attached agent, kept with its view. Nothing recalled is sent
  until `Enter`, and `Down` past the newest line brings the unfinished draft
  back. `Ctrl-G` opens the draft in the editor `$VISUAL` names, or `$EDITOR`,
  and puts what was saved back in the prompt, unsent; an editor that exits
  with any other status, or none that is set, leaves the draft as it was.

  `Ctrl-P` opens the command palette over the panes: every command that can
  run now, the ones run lately first, narrowed as letters are typed. `Up`,
  `Down` and `Tab` choose, `Enter` runs the chosen command or asks for what
  it needs, one step at a time: an agent or a node picked from a list, a
  parked call picked by number, or text typed after the usage shown.
  `Backspace` on an empty query goes back a step, and `Esc` closes the palette
  with the draft and focus as they were. A command run from the palette goes
  through the same parser as one typed, so `/rm` still previews what goes and
  waits for `/confirm`.

  `Esc` in the prompt, with nothing else to dismiss, stops the turn or
  abandons a parked one, as does `Ctrl-X` then `s` from any pane. `Ctrl-C`
  leaves at once, as Breeze has it, taking any agent this node runs with it.
  `Ctrl-D` quits from the prompt when nothing is typed; in the transcript it
  scrolls half a page down, as `Ctrl-U` scrolls up, alongside `j`, `k`,
  `PageUp`, `PageDown`, `Home` and `End`. `Ctrl-F` shows and hides the
  panel. `Ctrl-T` toggles tracing. `/stop` and `/quit` do the same as the
  keys.

  The commands are defined in `TarsTUI.Command`, which is also what `/help`
  reads.
  """
  use Breeze.View
  import Breeze.Blocks

  alias Tars.Agent
  alias Tars.Delegation
  alias Tars.Event
  alias Tars.Fleet
  alias Tars.LLM
  alias TarsTUI.Activity
  alias TarsTUI.Command
  alias TarsTUI.Exchange
  alias TarsTUI.Fleet.Filter
  alias TarsTUI.History
  alias TarsTUI.Markdown
  alias TarsTUI.Palette
  alias TarsTUI.Render
  alias TarsTUI.Search
  alias TarsTUI.Table
  alias TarsTUI.Text
  alias TarsTUI.Transcript
  alias TarsTUI.Usage
  alias TarsTUI.View

  @tick 100
  # The fleet republishes on every transition, so a busy turn would redraw the
  # panel constantly. One refresh per window is enough to read.
  @fleet_after 200
  @min_log_width 40
  @thinking_tail 240
  # Header, the status row, and meta.
  @chrome_rows 3
  @max_prompt_rows 8
  @faint [:faint, :light_black]

  # What is kept for an agent when this client connects elsewhere, and put
  # back when it connects again.
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
    :frame,
    :tools,
    :answer_text,
    :search
  ]

  # How long a brief notice stays on the status row.
  @notice_after 4_000

  @default_denial "Denied by the person watching."

  # How long the leader waits for a direction.
  @leader_after 1_500

  @doc "The fleet panel's width in columns, unless started with `:sidebar_width`."
  @spec default_sidebar_width() :: pos_integer()
  def default_sidebar_width, do: @sidebar_width

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
      {"ArrowUp", "Older", &__MODULE__.older/2},
      {"ArrowDown", "Newer", &__MODULE__.newer/2},
      {"^g", "Edit", &__MODULE__.edit/2},
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
  def approve(_event, term), do: {:noreply, decide(term, nil, :approve)}

  # In the transcript, `/` searches it, `n` and `N` step through the matches,
  # `t` picks a tool call to see in full and `y` copies the answer. Anywhere
  # else the letters are typed.
  @doc false
  def search(_event, %{focused: "log"} = term), do: {:noreply, open_search(term, "")}
  def search(_event, _term), do: :continue

  @doc false
  def next_match(_event, %{focused: "log"} = term), do: {:noreply, step_match(term, :next)}
  def next_match(_event, _term), do: :continue

  @doc false
  def previous_match(_event, %{focused: "log"} = term),
    do: {:noreply, step_match(term, :previous)}

  def previous_match(_event, _term), do: :continue

  @doc false
  def tools(_event, %{focused: "log"} = term), do: {:noreply, open_tools(term)}
  def tools(_event, _term), do: :continue

  @doc false
  def copy(_event, %{focused: "log"} = term), do: {:noreply, copy_text(term, :answer)}
  def copy(_event, _term), do: :continue

  @doc false
  def deny(_event, term), do: {:noreply, decide(term, nil, {:deny, @default_denial})}

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
        {:noreply, focus_pane(term, "prompt")}

      narrow?(term) ->
        {:noreply, focus_pane(term, "fleet")}

      term.focused == "fleet" ->
        {:noreply, term |> assign(sidebar?: false) |> focus_pane("prompt")}

      true ->
        {:noreply, term |> assign(sidebar?: false) |> sync_pane()}
    end
  end

  def toggle_fleet(_event, term),
    do: {:noreply, term |> assign(sidebar?: true) |> refresh_fleet() |> sync_pane()}

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
    do: {:noreply, term |> close_inspector() |> focus_pane("prompt")}

  def to_prompt(_event, %{focused: focused} = term) when focused in ["log", "fleet"],
    do: {:noreply, focus_pane(term, "prompt")}

  def to_prompt(_event, _term), do: :continue

  # Cancels a pending leader, or returns to the prompt from another pane. In
  # the prompt, with nothing else to dismiss, it stops the turn, or abandons a
  # parked one; idle, it does nothing.
  @doc false
  def back(_event, %{assigns: %{palette: %{}}} = term), do: {:noreply, close_palette(term)}

  def back(_event, %{assigns: %{inspecting: {_kind, _what, _where}}} = term),
    do: {:noreply, close_inspector(term)}

  def back(_event, %{assigns: %{leader: {_ref, _origin}}} = term), do: {:noreply, unlead(term)}

  def back(_event, %{focused: "prompt"} = term) do
    term = sync_pane(term)
    if busy?(term), do: {:noreply, interrupt(term)}, else: {:noreply, term}
  end

  def back(_event, term), do: {:noreply, focus_pane(term, "prompt")}

  defp busy?(%{assigns: %{running?: running?, parked: parked}}), do: running? or parked != []

  # Recalls an older line when the cursor is on the prompt's first line, and
  # leaves the key to the prompt otherwise, where it moves the cursor up.
  @doc false
  def older(_event, %{focused: "prompt", assigns: %{leader: nil}} = term) do
    %{value: value, cursor: cursor} = prompt(term)

    if first_line?(value, cursor), do: {:noreply, recall(term, :back)}, else: :continue
  end

  def older(_event, _term), do: :continue

  # Recalls a newer line when the cursor is on the prompt's last line.
  @doc false
  def newer(_event, %{focused: "prompt", assigns: %{leader: nil}} = term) do
    %{value: value, cursor: cursor} = prompt(term)

    if last_line?(value, cursor), do: {:noreply, recall(term, :forward)}, else: :continue
  end

  def newer(_event, _term), do: :continue

  defp prompt(term) do
    draft = term.assigns.draft
    Map.merge(%{value: draft, cursor: String.length(draft)}, implicit_state(term, "prompt"))
  end

  defp first_line?(value, cursor), do: not String.contains?(String.slice(value, 0, cursor), "\n")

  defp last_line?(value, cursor),
    do: not String.contains?(String.slice(value, cursor, String.length(value)), "\n")

  # The list walked is the one entered: the commands when the draft starts
  # with a slash, otherwise the attached agent's prompts.
  defp recall(term, direction) do
    which = term.assigns.walking || which(term.assigns.draft)
    history = term.assigns[which]

    step =
      case direction do
        :back -> History.back(history, term.assigns.draft)
        :forward -> History.forward(history)
      end

    case step do
      :none ->
        term

      {line, history} ->
        term
        |> assign([{which, history}, {:walking, if(History.browsing?(history), do: which)}])
        |> put_draft(line)
    end
  end

  defp which("//" <> _rest), do: :history
  defp which("/" <> _rest), do: :commands
  defp which(_draft), do: :history

  # The draft as the prompt shows it, with the cursor at its end.
  defp put_draft(term, line) do
    at = String.length(line)

    term
    |> assign(draft: line)
    |> update_implicit("prompt", fn {_module, state} ->
      %{state | value: line, cursor: at, preferred_column: nil}
    end)
  end

  # Records a line entered: a question in the attached agent's history, a
  # slash command in the client's; an answer to a parked call in neither.
  defp remember(term, value, command) do
    term = leave(term)

    case {command, String.trim(value)} do
      {{:ask, _text}, line} ->
        assign(term, history: History.push(term.assigns.history, line))

      {_other, "/" <> _rest = line} ->
        assign(term, commands: History.push(term.assigns.commands, line))

      _answer ->
        term
    end
  end

  defp leave(term) do
    assign(term,
      walking: nil,
      history: History.leave(term.assigns.history),
      commands: History.leave(term.assigns.commands)
    )
  end

  # Opens the draft in the editor, from any pane, unless one is open already.
  # The editor runs in a process of its own and answers with `{:edited, ref,
  # result}`; the agent the draft belongs to is remembered with it.
  @doc false
  def edit(_event, %{assigns: %{palette: %{}}} = term), do: {:noreply, term}

  def edit(_event, %{assigns: %{editing: nil}} = term) do
    %{draft: draft, agent_id: agent_id, editor: editor} = term.assigns
    view = self()
    ref = make_ref()
    context = %{terminal: term.terminal, server: term.server}
    {pid, _monitor} = spawn_monitor(fn -> send(view, {:edited, ref, editor.(draft, context)}) end)

    {:noreply, term |> assign(editing: {ref, agent_id, pid}) |> focus_pane("prompt")}
  end

  def edit(_event, term), do: {:noreply, sync_pane(term)}

  # What the editor saved becomes the draft of the agent it was opened for:
  # the prompt when that agent is still attached, its kept view otherwise. An
  # editor that failed leaves the draft as it was and says why.
  defp edited(%{assigns: %{agent_id: agent_id}} = term, agent_id, {:ok, text}),
    do: put_draft(term, text)

  defp edited(term, agent_id, {:ok, text}) do
    case term.assigns.views do
      %{^agent_id => kept} ->
        kept = %{kept | draft: text, prompt: %{}}
        assign(term, views: Map.put(term.assigns.views, agent_id, kept))

      _views ->
        term
    end
  end

  defp edited(term, _agent_id, {:error, {:exit, _status} = reason}),
    do: flash(term, View.editor_failed(reason))

  defp edited(term, _agent_id, {:error, reason}), do: append(term, View.editor_failed(reason))

  # -- the palette -----------------------------------------------------------

  # Opens the palette over the panes, remembering where focus came from, or
  # closes it.
  @doc false
  def palette(_event, %{assigns: %{palette: nil}} = term) do
    palette = %Palette{step: :commands, origin: term.focused || "prompt"}
    {:noreply, term |> open_palette(palette) |> refresh_fleet()}
  end

  def palette(_event, term), do: {:noreply, close_palette(term)}

  # Opens the palette at the next argument `command` needs after `chosen`,
  # with `query` already typed, as a command missing an argument does.
  defp pick(term, name, chosen, query \\ "") do
    command = Command.find(name)
    step = Enum.at(command.arguments, length(chosen))
    palette = %Palette{step: step, command: command, chosen: chosen, query: query}

    term |> open_palette(palette) |> refresh_fleet()
  end

  # Every key and command over the panes, searched like the palette; Enter on
  # a command runs it.
  defp open_help(term),
    do: open_palette(term, %Palette{step: :help, origin: term.focused || "prompt"})

  defp open_palette(term, %Palette{} = palette),
    do: term |> assign(palette: palette, leader: nil) |> focus("palette")

  # The transcript's matching rows, narrowed as letters are typed; Enter goes
  # to one.
  defp open_search(term, query),
    do:
      open_palette(term, %Palette{step: :search, query: query, origin: term.focused || "prompt"})

  # The conversation's tool calls; Enter opens one in the inspector.
  defp open_tools(%{assigns: %{tools: []}} = term), do: flash(term, View.no_tools())

  defp open_tools(term),
    do: open_palette(term, %Palette{step: :tool, origin: term.focused || "prompt"})

  defp close_palette(%{assigns: %{palette: %{origin: origin}}} = term),
    do: term |> assign(palette: nil) |> focus_pane(origin)

  defp close_palette(term), do: term

  defp update_palette(%{assigns: %{palette: nil}} = term, _fun), do: term
  defp update_palette(term, fun), do: assign(term, palette: fun.(term.assigns.palette))

  # Back to choosing a command, with nothing chosen.
  defp restart_palette(term) do
    update_palette(term, &%{&1 | step: :commands, command: nil, chosen: [], query: "", cursor: 0})
  end

  # The agents offered are the fleet as it is now.
  defp step_palette(term, step, command, chosen) do
    term = if step == :agent, do: refresh_fleet(term), else: term

    update_palette(
      term,
      &%{&1 | step: step, command: command, chosen: chosen, query: "", cursor: 0}
    )
  end

  # What the palette offers at its step, narrowed to the query: `{value, row}`
  # pairs, the value being what the command is given.
  defp choices(%{palette: %{step: :commands, query: query}} = assigns) do
    recent = assigns.recent

    {first, rest} =
      assigns |> context() |> Command.palette() |> Enum.split_with(&(&1.name in recent))

    first
    |> Enum.sort_by(&Enum.find_index(recent, fn name -> name == &1.name end))
    |> Kernel.++(rest)
    |> Enum.map(&{&1, View.palette_command(&1, &1.name in recent)})
    |> Palette.filter(query, fn {command, _row} -> command.label <> " " <> command.name end)
  end

  defp choices(%{palette: %{step: :agent, query: query}} = assigns) do
    assigns.fleet
    |> Enum.map(&{&1.key, agent_row(&1)})
    |> Palette.filter(query, &elem(&1, 0))
  end

  defp choices(%{palette: %{step: :node, query: query}}) do
    [node() | Node.list()]
    |> Enum.map(&{Atom.to_string(&1), node_row(&1)})
    |> Palette.filter(query, &elem(&1, 0))
  end

  defp choices(%{palette: %{step: :call, query: query}} = assigns) do
    assigns.parked
    |> Enum.with_index(1)
    |> Enum.map(fn {{call, prompt}, index} -> {"#{index}", call_row(call, prompt, index)} end)
    |> Palette.filter(query, fn {_index, row} -> Text.plain(row) end)
  end

  defp choices(%{palette: %{step: :text}}), do: []

  defp choices(%{palette: %{step: :search, query: query}} = assigns) do
    assigns.transcript
    |> Transcript.find(query)
    |> Enum.map(fn {row, text} -> {row, View.search_row(row, text)} end)
  end

  defp choices(%{palette: %{step: :tool, query: query}} = assigns) do
    assigns.tools
    |> Enum.with_index(1)
    |> Enum.map(fn {exchange, index} -> {index, View.tool_row(exchange, index)} end)
    |> Palette.filter(query, fn {_index, row} -> Text.plain(row) end)
  end

  # With nothing typed the keys come first; with a query, the commands do.
  defp choices(%{palette: %{step: :help, query: query, origin: origin}} = assigns) do
    context = context(assigns)
    keys = Enum.map(View.help_keys(origin), &{:key, &1})

    commands =
      Enum.map(
        Command.all(),
        &{{:command, &1}, View.help_command(&1, Command.available?(&1, context))}
      )

    rows = if query == "", do: keys ++ commands, else: commands ++ keys
    Palette.filter(rows, query, fn {_value, row} -> Text.plain(row) end)
  end

  defp agent_row(member) do
    elsewhere = if member.node == node(), do: "", else: " · @#{short_node(member.node)}"
    [Text.tag(member.key, :bright), Text.tag("  #{member.status}#{elsewhere}", @faint)]
  end

  defp node_row(name) do
    [
      Text.tag(Atom.to_string(name), :bright),
      if(name == node(), do: Text.tag("  this node", @faint), else: [])
    ]
  end

  defp call_row(call, prompt, index),
    do: [
      Text.tag("#{index}  ", @faint),
      Text.tag(call.name, :bright),
      Text.tag("  #{prompt}", @faint)
    ]

  defp short_node(node), do: node |> Atom.to_string() |> String.split("@", parts: 2) |> hd()

  defp context(assigns) do
    %{
      busy?: assigns.running? or assigns.parked != [],
      parked: length(assigns.parked),
      confirm?: assigns.confirm != nil,
      nodes: 1 + length(Node.list()),
      attention: length(attention(assigns))
    }
  end

  # Enter on a row: a command starts collecting its arguments, a value chosen
  # is one of them, and text typed is the last.
  defp choose(term, %{step: :text, command: command, chosen: chosen, query: query}, _choice),
    do: run(term, command, chosen ++ [String.trim(query)])

  defp choose(term, _palette, nil), do: {:noreply, term}
  defp choose(term, %{step: :commands}, {command, _row}), do: advance(term, command, [])
  defp choose(term, %{step: :help}, {{:command, command}, _row}), do: advance(term, command, [])
  defp choose(term, %{step: :help}, {:key, _row}), do: {:noreply, term}

  defp choose(term, %{step: :search, query: query}, {row, _text}) do
    search = Search.new(query, term.assigns.transcript, row)
    count = length(Search.rows(term.assigns.transcript, query))

    {:noreply,
     term
     |> close_palette()
     |> assign(search: search)
     |> go_to_row(row)
     |> flash(View.match(query, search.at + 1, count))}
  end

  defp choose(term, %{step: :tool, origin: origin}, {index, _row}),
    do: {:noreply, term |> close_palette() |> inspect_tool(index, origin)}

  defp choose(term, %{command: command, chosen: chosen}, {value, _row}),
    do: advance(term, command, chosen ++ [value])

  # The next argument to collect, or the command run with what was collected.
  # One parked call needs no choosing.
  defp advance(term, command, chosen) do
    case {Enum.at(command.arguments, length(chosen)), term.assigns.parked} do
      {nil, _calls} -> run(term, command, chosen)
      {:call, [_only]} -> run(term, command, chosen)
      {step, _calls} -> {:noreply, step_palette(term, step, command, chosen)}
    end
  end

  # The command as it would have been typed, run the same way.
  defp run(term, command, chosen) do
    words =
      command.arguments
      |> Enum.zip(chosen)
      |> Enum.map(fn
        {:node, name} -> "node=" <> name
        {_step, value} -> value
      end)
      |> Enum.reject(&(&1 == ""))

    recent = Enum.take([command.name | List.delete(term.assigns.recent, command.name)], 5)

    term
    |> assign(recent: recent)
    |> close_palette()
    |> run_line(Enum.join([command.name | words], " "))
  end

  # Reads a line as the prompt would, records it, and acts on it. A line that
  # named no command, or gave one the wrong thing, is put back for correction.
  defp run_line(term, line) do
    command = Command.parse(line, term.assigns.parked != [])
    term = remember(term, line, command)

    case command do
      :quit ->
        {:stop, term}

      {mistake, _word} when mistake in [:unknown, :usage] ->
        {:noreply, command |> apply_command(term) |> put_draft(String.trim(line))}

      command ->
        {:noreply, apply_command(command, term)}
    end
  end

  # Enter in the panel: on an agent, connects; on a delegation, inspects it.
  @doc false
  def connect_highlighted(_event, term) do
    case String.split(term.assigns.highlighted || "", "\t", parts: 2) do
      [key, span_id] -> {:noreply, inspect_delegation(term, key, span_id)}
      [key] -> {:noreply, term |> connect_key(key) |> focus_pane("prompt")}
    end
  end

  # -- delegations -----------------------------------------------------------

  # The agent a panel row belongs to: its own key, or the key before the
  # delegation's span.
  defp agent_of(nil), do: nil
  defp agent_of(value), do: value |> String.split("\t", parts: 2) |> hd()

  # Shows an agent's delegations under its row. Another agent's come from its
  # snapshot and then its lifecycle events; the attached agent's are folded
  # here already.
  defp expand(term, nil), do: term

  defp expand(%{assigns: %{expanded: expanded, agent_id: agent_id}} = term, key) do
    cond do
      Map.has_key?(expanded, key) ->
        term

      key == agent_id ->
        term |> assign(expanded: Map.put(expanded, key, nil)) |> tick()

      true ->
        case Enum.find(term.assigns.fleet, &(&1.key == key)) do
          nil ->
            term

          member ->
            :ok = Event.Bus.subscribe(key, level: :lifecycle)
            term |> assign(expanded: Map.put(expanded, key, followed(member.pid))) |> tick()
        end
    end
  end

  defp followed(pid) do
    case Agent.snapshot(pid) do
      %{delegations: %Delegation{} = delegations} -> delegations
      _other -> Delegation.new()
    end
  catch
    :exit, _reason -> Delegation.new()
  end

  # Hides an agent's delegations until `l`, and stops following an agent that
  # is not the attached one. The cursor lands on the agent.
  defp collapse(term, nil), do: term

  defp collapse(%{assigns: %{expanded: expanded, agent_id: agent_id}} = term, key) do
    term = assign(term, collapsed: MapSet.put(term.assigns.collapsed, key))

    if Map.has_key?(expanded, key) do
      if key != agent_id, do: Event.Bus.unsubscribe(key)
      assign(term, expanded: Map.delete(expanded, key), highlighted: key)
    else
      term
    end
  end

  # Every agent in the fleet is expanded unless it was collapsed; one gone
  # from the fleet is no longer followed.
  defp expand_all(term, fleet) do
    keys = Enum.map(fleet, & &1.key)
    gone = Map.keys(term.assigns.expanded) -- keys
    Enum.each(gone, &if(&1 != term.assigns.agent_id, do: Event.Bus.unsubscribe(&1)))

    term =
      assign(term,
        expanded: Map.drop(term.assigns.expanded, gone),
        collapsed: MapSet.intersection(term.assigns.collapsed, MapSet.new(keys))
      )

    Enum.reduce(fleet, term, fn member, term ->
      if MapSet.member?(term.assigns.collapsed, member.key),
        do: term,
        else: expand(term, member.key)
    end)
  end

  # An expanded agent's delegations, or `nil` when it is not expanded.
  defp delegations(%{expanded: expanded, agent_id: agent_id} = assigns, key) do
    cond do
      not Map.has_key?(expanded, key) -> nil
      key == agent_id -> assigns.delegations
      true -> Map.fetch!(expanded, key)
    end
  end

  # An agent this client was attached to stays followed if it is expanded,
  # and one it attaches to is followed through its own subscription instead.
  defp refollow(term, old, key) do
    expanded = term.assigns.expanded

    if Map.has_key?(expanded, old) and old != key do
      :ok = Event.Bus.subscribe(old, level: :lifecycle)
      kept = term.assigns.views |> Map.get(old, %{}) |> Map.get(:delegations, Delegation.new())
      assign(term, expanded: Map.put(expanded, old, kept))
    else
      term
    end
  end

  defp inspect_delegation(term, key, span_id),
    do: open_inspector(term, {:delegation, key, span_id})

  defp inspect_tool(term, index, origin), do: open_inspector(term, {:tool, index, origin})

  defp open_inspector(term, inspecting),
    do: term |> assign(inspecting: inspecting, pane: "inspector") |> focus("inspector")

  # A delegation was opened from the panel; a tool call from wherever `t` or
  # `/tools` was.
  defp close_inspector(%{assigns: %{inspecting: {:tool, _index, origin}}} = term),
    do: term |> assign(inspecting: nil) |> focus_pane(origin)

  defp close_inspector(term), do: term |> assign(inspecting: nil) |> focus_pane("fleet")

  # The transcript scrolled so `row` is the top one shown, and focused.
  defp go_to_row(term, row) do
    term
    |> put_implicit("log", TarsTUI.Scroll, %{
      offset_y: row,
      autoscroll: "bottom",
      pinned_bottom: false
    })
    |> focus_pane("log")
  end

  defp step_match(%{assigns: %{search: nil}} = term, _direction),
    do: flash(term, View.nothing_searched())

  defp step_match(%{assigns: %{search: search}} = term, direction) do
    case Search.step(search, term.assigns.transcript, direction) do
      :none ->
        flash(term, View.no_match(search.query))

      {search, row, count} ->
        term
        |> assign(search: search)
        |> go_to_row(row)
        |> flash(View.match(search.query, search.at + 1, count))
    end
  end

  # The last answer, or its last code block, on the clipboard.
  defp copy_text(term, what) do
    with {:ok, text} <- to_copy(term.assigns.answer_text, what),
         :ok <- term.assigns.clipboard.(text) do
      flash(term, View.copied(what, String.length(text)))
    else
      {:error, why} -> flash(term, View.not_copied(why))
    end
  end

  defp to_copy("", _what), do: {:error, :no_answer}
  defp to_copy(text, :answer), do: {:ok, text}

  defp to_copy(text, :code) do
    case List.last(Markdown.code_blocks(text)) do
      nil -> {:error, :no_code}
      code -> {:ok, code}
    end
  end

  # A notice on the status row for a moment, in place of the transcript.
  defp flash(term, text) do
    ref = make_ref()
    Process.send_after(self(), {:notice_timeout, ref}, @notice_after)
    assign(term, notice: {ref, text})
  end

  # Whether the frame should keep ticking: for the elapsed times of a running
  # turn, or of delegations still going under an expanded agent.
  defp ticking?(%{assigns: %{running?: true}}), do: true

  defp ticking?(%{assigns: %{expanded: expanded}}) do
    Enum.any?(expanded, fn
      {_key, %Delegation{} = delegations} -> Delegation.summary(delegations).active > 0
      {_key, nil} -> false
    end)
  end

  defp tick(%{assigns: %{tick_due?: true}} = term), do: term

  defp tick(term) do
    Process.send_after(self(), :tick, @tick)
    assign(term, tick_due?: true)
  end

  # Leaves from the prompt with nothing typed. In the transcript the same key
  # scrolls half a page; anywhere else it does nothing.
  @doc false
  def quit(_event, %{focused: "log"}), do: :continue
  def quit(_event, %{focused: "prompt", assigns: %{draft: ""}} = term), do: {:stop, term}
  def quit(_event, term), do: {:noreply, sync_pane(term)}

  # The transcript sits above the prompt and left of the panel.
  defp neighbour("prompt", key, _fleet?) when key in ["k", "h"], do: "log"
  defp neighbour("prompt", "l", true), do: "fleet"
  defp neighbour("prompt", "l", false), do: "log"
  defp neighbour("log", "l", true), do: "fleet"
  defp neighbour("log", "j", _fleet?), do: "prompt"
  defp neighbour("fleet", "h", _fleet?), do: "log"
  defp neighbour("fleet", "j", _fleet?), do: "prompt"
  defp neighbour(pane, _key, _fleet?), do: pane

  # Focusing the panel refreshes it first, so the rows are current before the
  # cursor moves through them.
  defp focus_pane(term, "fleet"),
    do: term |> refresh_fleet() |> focus("fleet") |> assign(pane: "fleet")

  defp focus_pane(term, id), do: term |> focus(id) |> assign(pane: id)

  # Drops a pending leader and puts focus back where it came from.
  defp unlead(%{assigns: %{leader: {_ref, origin}}} = term),
    do: term |> assign(leader: nil) |> focus_pane(origin)

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

  defp led(term, "i", _origin), do: focus_pane(term, "prompt")

  defp led(term, "s", origin) do
    term = focus_pane(term, origin)
    if busy?(term), do: interrupt(term), else: term
  end

  defp led(term, key, origin), do: focus_pane(term, neighbour(origin, key, term.assigns.sidebar?))

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

  # Focus moves without this view hearing of it, on `Tab` for one, so the pane
  # the hints describe is read back whenever the view handles anything.
  defp sync_pane(term), do: assign(term, pane: term.focused || "prompt")

  @impl Breeze.View
  def mount(opts, term) do
    agent = Keyword.fetch!(opts, :agent)

    # Breeze applies a block's attribute defaults only when the module that
    # defines it is already loaded when the template first renders.
    {:module, Breeze.Blocks} = Code.ensure_loaded(Breeze.Blocks)
    :ok = Fleet.watch()

    term =
      term
      |> assign(
        spawn_opts: Keyword.get(opts, :spawn_opts, []),
        fleet: [],
        fleet_due?: false,
        sidebar?: Keyword.get(opts, :sidebar, true),
        sidebar_width: Keyword.get(opts, :sidebar_width, @sidebar_width),
        unseen: %{},
        filter: Filter.none(),
        model: Keyword.get(opts, :model, ""),
        verbose?: Keyword.get(opts, :verbose, false),
        editor: Keyword.get(opts, :editor, &TarsTUI.Editor.edit/2),
        clipboard: Keyword.get(opts, :clipboard, &TarsTUI.Clipboard.copy/1),
        notice: nil,
        tools: [],
        answer_text: "",
        search: nil,
        views: %{},
        available?: true,
        confirm: nil,
        pane: "prompt",
        leader: nil,
        palette: nil,
        recent: [],
        expanded: %{},
        collapsed: MapSet.new(),
        inspecting: nil,
        delegations: Delegation.new(),
        editing: nil,
        walking: nil,
        commands: History.new(),
        history: History.new(),
        frame: 0,
        frame_due?: false,
        frame_after: @frame_after,
        frame_at: nil,
        tick_due?: false,
        started_at: nil,
        draft: ""
      )
      |> attach(agent, Keyword.get(opts, :agent_id, agent))
      |> refresh_fleet()
      |> append_lines(banner())
      |> put_focus_keybindings("fleet", [{"Enter", "Connect", &__MODULE__.connect_highlighted/2}])
      |> focus_pane("prompt")

    {:ok, term}
  end

  # Subscribes to `agent`'s events and shows its conversation: the transcript
  # kept from the last time this client watched it, brought up to date, or a
  # replay of the whole conversation. `agent_id` is what the events are
  # published under.
  defp attach(term, agent, agent_id) do
    # `:raw` delivers `{:tool_call, chunk}` with its arguments.
    :ok = Event.Bus.subscribe(agent_id, level: :raw)

    case snapshot(agent) do
      {:ok, snapshot} -> attach_snapshot(term, agent, agent_id, snapshot)
      {:error, _reason} -> assign(term, available?: false)
    end
  end

  defp snapshot(agent) do
    case Agent.snapshot(agent) do
      {:error, reason} -> {:error, reason}
      snapshot -> {:ok, snapshot}
    end
  catch
    :exit, reason -> {:error, reason}
  end

  defp attach_snapshot(term, agent, agent_id, snapshot) do
    %{
      status: %{state: state, pending: pending, model: model},
      context: %{messages: messages},
      parked: parked,
      generation: generation,
      trace_id: trace_id
    } = snapshot

    term =
      term
      |> assign(
        agent: agent,
        agent_id: agent_id,
        highlighted: agent_id,
        model: model,
        generation: generation,
        trace_id: trace_id,
        activity: Activity.new(),
        running?: state == :running,
        queued: pending,
        available?: true,
        confirm: nil
      )

    case Map.pop(term.assigns.views, agent_id) do
      {nil, _views} ->
        term |> fresh(messages) |> parked_notice(parked)

      {%{generation: ^generation} = kept, views} ->
        term |> assign(views: views) |> restore(kept, messages, parked)

      {_deleted, views} ->
        term |> assign(views: views) |> fresh(messages) |> parked_notice(parked)
    end
    |> assign(
      parked: parked,
      delegations: Map.get(snapshot, :delegations, Delegation.new()),
      unseen: Map.delete(term.assigns.unseen, agent_id)
    )
  end

  defp fresh(term, messages) do
    term
    |> assign(
      transcript: Transcript.new(width(term)),
      answer: Markdown.new(),
      reasoning: Markdown.new(),
      thinking: "",
      chars: 0,
      answering?: false,
      usage: Usage.new(term.assigns.model),
      unread: 0,
      draft: "",
      history: History.new(),
      delegations: Delegation.new(),
      tools: [],
      answer_text: "",
      search: nil,
      started_at: nil,
      frame: 0,
      seen: length(messages)
    )
    |> reset("prompt")
    |> reset("log")
    |> playback(messages)
  end

  # What was kept comes back as it was, and the messages the conversation
  # gained meanwhile are replayed under a note. A park that happened while
  # away is announced as it would have been live.
  defp restore(term, kept, messages, parked) do
    unseen = Enum.drop(messages, kept.seen)
    same_turn? = term.assigns.trace_id == kept.trace_id
    activity = if same_turn?, do: kept.activity, else: Activity.new()
    restored = Map.drop(kept, [:generation, :trace_id, :activity])

    term
    |> assign(restored |> Map.take(@kept) |> Map.put(:seen, length(messages)) |> Enum.to_list())
    |> assign(activity: activity)
    |> restore_prompt(kept.prompt)
    |> put_implicit("log", TarsTUI.Scroll, kept.scroll)
    |> away(unseen)
    |> parked_notice(if(kept.parked != parked, do: parked, else: []))
  end

  defp restore_prompt(term, prompt) when map_size(prompt) == 0, do: reset(term, "prompt")

  defp restore_prompt(term, prompt),
    do: put_implicit(term, "prompt", Breeze.Implicit.Textarea, prompt)

  defp away(term, []), do: term

  defp away(term, messages) do
    term |> append(View.away(length(messages))) |> playback(messages)
  end

  # Keeps the view of the attached agent for the next time it is connected to.
  defp keep(term) do
    term = settle(term)
    seen = seen(term)

    kept =
      term.assigns
      |> Map.take(@kept)
      |> Map.merge(%{
        seen: seen,
        scroll: implicit_state(term, "log"),
        prompt: implicit_state(term, "prompt")
      })

    assign(term, views: Map.put(term.assigns.views, term.assigns.agent_id, kept))
  end

  # How many messages the conversation holds now, or the count last known when
  # the agent cannot be asked.
  defp seen(%{assigns: %{agent: agent, seen: seen}}) do
    case Agent.get_context(agent) do
      %ReqLLM.Context{messages: messages} -> length(messages)
      {:error, :not_found} -> seen
    end
  catch
    :exit, _reason -> seen
  end

  defp implicit_state(%{implicit_state: states}, id) do
    case Map.get(states, id) do
      {_module, state} -> state
      nil -> %{}
    end
  end

  # The conversation as the transcript would have shown it: what the person
  # asked, what the agent answered, and each tool call with what it returned.
  defp playback(term, messages), do: Enum.reduce(messages, term, &play/2)

  defp play(%{role: :user} = message, term), do: question(term, LLM.Context.text(message))

  defp play(%{role: :assistant} = message, term) do
    term |> say(LLM.Context.text(message)) |> calls(message.tool_calls || [])
  end

  defp play(%{role: :tool} = message, term) do
    output = LLM.Context.text(message)
    ok? = tool_ok?(message, output)
    name = message.name || "tool"

    term
    |> append(View.tool_result(name, output, ok?))
    |> assign(tools: Exchange.finish(term.assigns.tools, message.tool_call_id, name, output, ok?))
  end

  defp play(_system_message, term), do: term

  defp say(term, ""), do: term

  defp say(term, text) do
    {streamed, answer} = Markdown.push(Markdown.new(), text)
    {rest, _answer} = Markdown.flush(answer)

    term |> assign(answering?: false, answer_text: text) |> answer_lines(streamed ++ rest)
  end

  defp calls(term, tool_calls) do
    Enum.reduce(tool_calls, term, fn call, term ->
      %{id: id, name: name, arguments: arguments} = ReqLLM.ToolCall.from_map(call)

      term
      |> append(View.tool_call(name, arguments))
      |> assign(tools: Exchange.call(term.assigns.tools, id, name, arguments))
    end)
  end

  # A result is a failure when the runner marked it so, or when the tool
  # itself reported one through `Tars.Tool.Result.error/1`.
  defp tool_ok?(%{metadata: %{is_error: true}}, _output), do: false

  defp tool_ok?(_message, output) do
    not match?({:ok, %{"ok" => false}}, JSON.decode(output))
  end

  defp parked_notice(term, []), do: term
  defp parked_notice(term, calls), do: append(term, View.parked(calls))

  defp question(term, text), do: append_lines(term, ["", View.question(text)])

  defp banner,
    do: [
      Text.tag(
        "Enter sends · Esc stops · Ctrl-X then h/j/k/l moves · /help for the rest",
        @faint
      )
    ]

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
    overlay? = assigns.sidebar? and side_width == 0 and assigns.pane == "fleet"
    panel_width = if overlay?, do: assigns.sidebar_width, else: side_width
    shown = shown(assigns)
    fleet_rows = fleet_rows(assigns, shown, panel_width, overlay?)

    choices = if assigns.palette, do: choices(assigns), else: []
    {inspector_source, inspector_class} = inspector(assigns, width, height)

    assigns =
      assign(assigns,
        inspector_source: inspector_source,
        inspector_class: inspector_class,
        palette_count: length(choices),
        palette_class: palette_class(assigns.palette, choices, width, height),
        palette_content: palette_content(assigns, choices, width, height),
        source: Transcript.source(assigns.transcript),
        log_height: log_height,
        log_class: log_class(width - side_width, log_height),
        side_width: side_width,
        fleet_overlay?: overlay?,
        fleet_overlay_class: overlay_class(fleet_rows, panel_width, height),
        fleet_rows: fleet_rows,
        heading: heading(assigns, shown, panel_width),
        prompt_class:
          "block w-full h-#{prompt_height} bg-none border-surface focus:border-primary " <>
            "placeholder:text-8",
        placeholder: placeholder(assigns),
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
          br-change="scroll"
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
          <.fleet_panel
            heading={@heading}
            rows_height={@log_height - 1}
            highlighted={@highlighted}
            fleet_rows={@fleet_rows}
          />
        </box>
      </box>
      <box :if={@fleet_overlay?} class={@fleet_overlay_class}>
        <.fleet_panel
          heading={@heading}
          rows_height={length(@fleet_rows) + 2}
          highlighted={@highlighted}
          fleet_rows={@fleet_rows}
        />
      </box>
      <box class="block w-full h-1 overflow-hidden">{@status}</box>
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
      <box class="block w-full h-1 overflow-hidden">{@meta}</box>
      <box
        :if={@inspecting != nil}
        id="inspector"
        focusable
        implicit={TarsTUI.Scroll}
        class={@inspector_class}
      >
        {@inspector_source}
      </box>
      <box
        :if={@palette != nil}
        id="palette"
        focusable
        br-change="palette"
        br-submit="palette_run"
        implicit={TarsTUI.Palette}
        palette-query={@palette.query}
        palette-cursor={@palette.cursor}
        palette-count={@palette_count}
        class={@palette_class}
      >
        {@palette_content}
      </box>
    </box>
    """
  end

  # The palette sits centred over the panes, as wide as the terminal allows up
  # to a limit, and as tall as its rows need: the borders, the title, the query
  # and a rule, then the rows.
  @palette_width 72
  @palette_rows 12
  @palette_chrome 5

  # Help takes the room it can get; the palette keeps to a few rows.
  defp palette_size(%{step: :help}, choices, width, height) do
    rows = choices |> length() |> max(1) |> min(max(height - @palette_chrome - 2, 1))
    {max(width - 4, 20), min(rows + @palette_chrome, height - 2) |> max(6)}
  end

  defp palette_size(_palette, choices, width, height) do
    rows = choices |> length() |> max(1) |> min(@palette_rows)
    {min(width - 4, @palette_width) |> max(20), min(rows + @palette_chrome, height - 2) |> max(6)}
  end

  defp palette_class(palette, choices, width, height) do
    {w, h} = palette_size(palette, choices, width, height)

    "fixed center width-#{w} height-#{h} layer-50 bg-panel border-rounded border-primary overflow-hidden"
  end

  defp palette_content(%{palette: nil}, _choices, _width, _height), do: ""

  defp palette_content(%{palette: palette}, choices, width, height) do
    {w, h} = palette_size(palette, choices, width, height)
    title = View.palette_title(palette.step, palette.command)
    View.palette(title, palette.query, Enum.map(choices, &elem(&1, 1)), palette.cursor, w, h)
  end

  # The fleet panel: its heading and the list of rows, wherever it is placed.
  defp fleet_panel(assigns) do
    ~H"""
    <box class="block w-full h-1 overflow-hidden">{@heading}</box>
    <box class={"block w-full h-#{@rows_height} overflow-hidden"}>
      <.list
        id="fleet"
        br-change="highlight"
        list-selected={@highlighted}
        selected-indicator=" "
        class="height-full scrollbar-mute-100 border-line border-surface focus:border-primary"
        item_class="selected:bg-surface selected:text-muted"
      >
        <:item :for={{key, row} <- @fleet_rows} value={key}>{row}</:item>
      </.list>
    </box>
    """
  end

  # Over the panes, at the right, as tall as its rows need.
  defp overlay_class(rows, width, height) do
    rows_height = min(length(rows) + 2, max(height - 5, 3))

    "fixed right-1 top-1 width-#{width} height-#{rows_height + 1} layer-40 bg-panel " <>
      "overflow-hidden padding-left-1"
  end

  defp heading(_assigns, _shown, 0), do: ""

  defp heading(assigns, shown, width) do
    TarsTUI.Fleet.heading(
      length(shown),
      length(assigns.fleet),
      length(attention(assigns)),
      Filter.describe(assigns.filter),
      width
    )
  end

  defp log_class(width, height) do
    "inline overflow-scroll scrollbar-mute-100 w-#{width} h-#{height} " <>
      "border-b border-surface focus:border-primary"
  end

  # One list item per agent shown, as `{key, row}`, and under an expanded
  # agent one per delegation, as `{"key\tspan_id", row}`; each clipped to the
  # space inside the panel's gutter, the list's border and its selection
  # column.
  defp fleet_rows(_assigns, _shown, 0, _overlay?), do: []

  defp fleet_rows(assigns, shown, panel_width, overlay?) do
    now = System.system_time(:millisecond)
    ambiguous = TarsTUI.Fleet.ambiguous(assigns.fleet)
    width = panel_width - 4

    Enum.flat_map(shown, fn member ->
      rows =
        Enum.map(delegation_texts(assigns, member.key, now), fn {value, text} ->
          text = Text.truncate(text, width)
          {value, Render.line(if(overlay?, do: TarsTUI.Fleet.fill(text, width), else: text))}
        end)

      opts = [ambiguous: ambiguous, unseen: Map.get(assigns.unseen, member.key), pad?: overlay?]
      [{member.key, TarsTUI.Fleet.row(member, assigns.agent_id, width, opts)} | rows]
    end)
  end

  # The delegation rows under one agent, unclipped, as `{value, text}`.
  defp delegation_texts(assigns, key, now) do
    case delegations(assigns, key) do
      nil ->
        []

      delegations ->
        records = Delegation.list(delegations)
        count = length(records)

        records
        |> Enum.with_index(1)
        |> Enum.map(fn {record, index} ->
          depth = Delegation.depth(delegations, record.span_id)

          {key <> "\t" <> record.span_id,
           TarsTUI.Fleet.delegation(record, depth, index == count, now)}
        end)
    end
  end

  # The panel is as wide as it was configured, whatever its rows say, and is
  # left out beside the transcript on a terminal too narrow for both.
  defp sidebar_width(%{sidebar?: false}, _width), do: 0

  defp sidebar_width(%{sidebar_width: side}, width),
    do: if(width - side >= @min_log_width, do: side, else: 0)

  # The inspector sits centred over the panes, as tall as its lines need.
  @inspector_width 80

  defp inspector_size(rows, width, height) do
    {min(width - 6, @inspector_width) |> max(20), min(rows + 2, height - 2) |> max(5)}
  end

  defp inspector(%{inspecting: nil}, _width, _height), do: {"", ""}

  defp inspector(%{inspecting: {:delegation, key, span_id}} = assigns, width, height) do
    now = System.system_time(:millisecond)
    delegations = delegations(assigns, key) || Delegation.new()

    lines =
      case Delegation.fetch(delegations, span_id) do
        nil -> [Text.tag("this delegation is no longer shown · Esc closes", @faint)]
        record -> View.inspector(record, Delegation.activity(delegations, span_id), key, now)
      end

    inspector_box(lines, width, height)
  end

  defp inspector(%{inspecting: {:tool, index, _origin}} = assigns, width, height) do
    lines =
      case Enum.at(assigns.tools, index - 1) do
        nil -> [Text.tag("this tool call is no longer shown · Esc closes", @faint)]
        exchange -> View.tool_inspector(exchange, index)
      end

    inspector_box(lines, width, height)
  end

  # The lines laid out in a box centred over the panes, as tall as they need.
  defp inspector_box(lines, width, height) do
    {w, _h} = inspector_size(1, width, height)
    transcript = Transcript.append_all(Transcript.new(w - 4, pad?: true), lines)
    {_w, h} = inspector_size(Transcript.rows(transcript), width, height)

    {Transcript.source(transcript),
     "fixed center width-#{w} height-#{h} layer-50 bg-panel border-rounded border-primary " <>
       "overflow-scroll scrollbar-mute-100 padding-left-1"}
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

  # What Enter will do with the line, said where the line is typed.
  defp placeholder(%{available?: false}), do: "not running · nothing typed here is sent"

  defp placeholder(%{running?: true}),
    do: "Enter steers the turn at its next boundary · Esc stops it"

  defp placeholder(%{parked: [_only]}),
    do: "Enter queues behind the parked turn · y approve · n deny"

  defp placeholder(%{parked: [_ | _]}),
    do: "Enter queues behind the parked turn · /approve N · /deny N · /approve all"

  defp placeholder(_assigns), do: "Ask anything · /help"

  defp header(assigns) do
    [
      Render.tag(" tars", [:bright, :cyan]),
      if(assigns.verbose?, do: Render.tag(" [trace]", :yellow), else: ""),
      Render.dim(" · #{inspect(assigns.model)} · #{inspect(assigns.agent_id)}")
    ]
    |> Enum.join()
  end

  # A brief notice takes the row while it shows.
  defp status(%{notice: {_ref, text}}, width),
    do: Render.line(Render.justify([" ", text], "", width))

  defp status(%{available?: false, agent_id: key} = assigns, width) do
    {_org, _user, name} = Fleet.parse(key)

    left =
      Text.tag(
        " ⏻ #{key} is not running · the fleet restarts it if it can · /spawn #{name} brings it back",
        :yellow
      )

    Render.line(Render.justify(left, right(assigns), width))
  end

  defp status(%{running?: false, parked: [_ | _] = parked} = assigns, width) do
    names = Enum.map_join(parked, ", ", fn {call, _prompt} -> call.name end)
    left = Text.tag(" ? waiting on #{names} · #{decision_keys(parked)}", [:bright, :yellow])
    Render.line(Render.justify(left, right(assigns), width))
  end

  defp status(%{running?: false} = assigns, width) do
    left = Text.tag(" idle · type a prompt and press Enter", @faint)
    Render.line(Render.justify(left, right(assigns), width))
  end

  defp status(%{leader: {_ref, _origin}} = assigns, width) do
    span = Activity.innermost(assigns.activity)
    head = [" ", Text.tag(View.spinner(assigns.frame), :cyan), " ", label(span)]
    Render.line(Render.justify(head, right(assigns), width))
  end

  defp status(assigns, width) do
    span = Activity.innermost(assigns.activity)
    right = [below(assigns), Text.tag([chars(assigns.chars), elapsed(assigns), " "], @faint)]
    label = Text.truncate(label(span), max(div(width, 3), 20))
    head = [" ", Text.tag(View.spinner(assigns.frame), :cyan), " ", label]
    room = width - Text.length(right) - Text.length(head) - 4
    left = [head, doing(span, assigns.thinking, room)]

    Render.line(Render.justify(left, right, width))
  end

  # The keys that matter where focus is, with word of output below the rows
  # shown when there is some.
  defp right(assigns), do: [below(assigns), hints(assigns)]

  defp below(%{unread: unread}) when unread > 0, do: View.new_below()
  defp below(_assigns), do: []

  # The keys that matter where focus is, named after the pane, or the
  # directions the leader takes.
  defp hints(%{leader: {_ref, origin}} = assigns) do
    moves =
      case origin do
        "prompt" -> ["k transcript" | if(assigns.sidebar?, do: ["l fleet"], else: [])]
        "log" -> if(assigns.sidebar?, do: ["l fleet"], else: []) ++ ["j prompt"]
        _fleet -> ["h transcript", "j prompt"]
      end

    stop = if busy?(%{assigns: assigns}), do: ["s stop"], else: []
    Text.tag(["Ctrl-X · ", Enum.join(moves ++ stop ++ ["Esc cancel"], " · "), " "], :yellow)
  end

  defp hints(%{palette: %{step: :text}}),
    do: Text.tag("type the rest · Enter run · Backspace back · Esc close ", :yellow)

  defp hints(%{palette: %{step: :help}}),
    do: Text.tag("type to search · Up/Down scroll · Enter run a command · Esc close ", :yellow)

  defp hints(%{palette: %{step: :search}}),
    do: Text.tag("type to search · Up/Down choose · Enter go there · Esc close ", :yellow)

  defp hints(%{palette: %{step: :tool}}),
    do: Text.tag("type to filter · Up/Down choose · Enter see it in full · Esc close ", :yellow)

  defp hints(%{palette: %{}}),
    do: Text.tag("type to filter · Up/Down choose · Enter run · Esc close ", :yellow)

  defp hints(%{editing: {_ref, _agent_id, _pid}}),
    do: Text.tag("editing the prompt · the screen returns when the editor closes ", :yellow)

  defp hints(%{pane: "log"}),
    do:
      Text.tag(
        "transcript · j/k scroll · Ctrl-U/D half page · / find · t tools · y copy · i prompt · Esc back ",
        @faint
      )

  defp hints(%{pane: "fleet"}),
    do:
      Text.tag(
        "fleet · j/k · l/h expand · n/a attention · Enter connect · i prompt · Esc back ",
        @faint
      )

  defp hints(%{pane: "inspector"}),
    do: Text.tag("inspector · j/k scroll · i prompt · Esc back ", @faint)

  defp hints(%{available?: false}),
    do: Text.tag("prompt · Ctrl-X pane · Ctrl-F fleet · Ctrl-D quit ", @faint)

  defp hints(%{parked: [_ | _]}), do: Text.tag("prompt · Esc abandon · Ctrl-D quit ", @faint)
  defp hints(_assigns), do: Text.tag("prompt · Ctrl-X pane · Ctrl-F fleet · Ctrl-D quit ", @faint)

  defp decision_keys([_only]), do: "y approve · n deny"
  defp decision_keys(_several), do: "/approve N · /deny N · /approve all"

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
    usage = Usage.summary(assigns.usage)
    left = Text.tag(if(usage == "", do: "", else: " observed here · " <> usage), @faint)
    Render.line(Render.justify(left, Text.tag(queued(assigns), @faint), width))
  end

  defp elapsed(%{started_at: started_at}) when is_integer(started_at) do
    "#{div(now() - started_at, 1_000)}s"
  end

  defp elapsed(_assigns), do: ""

  defp queued(%{queued: 0}), do: ""
  defp queued(%{queued: 1, running?: true}), do: "1 message steering the turn "
  defp queued(%{queued: n, running?: true}), do: "#{n} messages steering the turn "
  defp queued(%{queued: 1}), do: "1 message queued behind the parked turn "
  defp queued(%{queued: n}), do: "#{n} messages queued behind the parked turn "

  # -- input -----------------------------------------------------------------

  @impl Breeze.View
  def handle_event("draft", %{value: value}, %{assigns: %{leader: {_ref, _origin}}} = term),
    do: {:noreply, direction(term, value)}

  def handle_event("draft", %{value: value}, term),
    do: {:noreply, term |> assign(draft: value, pane: "prompt") |> leave()}

  def handle_event("highlight", %{value: key}, term),
    do: {:noreply, assign(term, highlighted: key, pane: "fleet")}

  def handle_event("scroll", %{pinned_bottom: pinned?}, term),
    do:
      {:noreply, assign(term, unread: if(pinned?, do: 0, else: term.assigns.unread), pane: "log")}

  def handle_event("ask", %{value: value}, term),
    do: term |> assign(draft: "", leader: nil) |> reset("prompt") |> run_line(value)

  def handle_event("palette", %{action: :close}, term), do: {:noreply, close_palette(term)}

  def handle_event("palette", %{action: :back}, %{assigns: %{palette: %{step: step}}} = term)
      when step in [:commands, :help, :search, :tool],
      do: {:noreply, term}

  def handle_event("palette", %{action: :back}, term), do: {:noreply, restart_palette(term)}

  def handle_event("palette", %{query: query, cursor: cursor}, term),
    do: {:noreply, update_palette(term, &%{&1 | query: query, cursor: cursor})}

  def handle_event("palette_run", _event, %{assigns: %{palette: nil}} = term),
    do: {:noreply, term}

  def handle_event("palette_run", %{cursor: cursor}, %{assigns: %{palette: palette}} = term),
    do: choose(term, palette, Enum.at(choices(term.assigns), cursor))

  def handle_event(:input, %{"key" => "l"}, %{focused: "fleet"} = term) do
    key = agent_of(term.assigns.highlighted)
    collapsed = MapSet.delete(term.assigns.collapsed, key)
    {:noreply, term |> assign(collapsed: collapsed) |> expand(key)}
  end

  def handle_event(:input, %{"key" => "h"}, %{focused: "fleet"} = term),
    do: {:noreply, collapse(term, agent_of(term.assigns.highlighted))}

  def handle_event(:input, %{"key" => "n"}, %{focused: "fleet"} = term),
    do: {:noreply, highlight_next(term)}

  def handle_event(:input, %{"key" => "a"}, %{focused: "fleet"} = term),
    do: {:noreply, toggle_attention(term)}

  def handle_event(_name, _event, term), do: {:noreply, term}

  defp apply_command(:blank, term), do: term
  defp apply_command(:confirm, term), do: confirm(term)

  # Anything but `/confirm` drops a removal or a move that was waiting on it.
  defp apply_command(command, %{assigns: %{confirm: pending}} = term) when pending != nil do
    cancelled = View.cancelled(elem(pending, 0))
    apply_command(command, term |> assign(confirm: nil) |> append(cancelled))
  end

  defp apply_command({:stop, nil}, term), do: interrupt(term)
  defp apply_command({:stop, target}, term), do: stop(term, target)
  defp apply_command({:shutdown, name}, term), do: shutdown(term, name)
  defp apply_command({:rm, target, confirmed?}, term), do: remove(term, target, confirmed?)
  defp apply_command({:approve, selector}, term), do: decide(term, selector, :approve)
  defp apply_command(:fleet, term), do: show_fleet(term)
  defp apply_command(:help, term), do: open_help(term)

  defp apply_command({:deny, selector, reason}, term),
    do: decide(term, selector, {:deny, reason || @default_denial})

  defp apply_command({:spawn, name, options, prompt, mode}, term),
    do: spawn_agent(term, name, options, prompt, mode)

  defp apply_command({:move, nil, _options}, term), do: pick(term, "/move", [])

  defp apply_command({:move, name, options}, term) when map_size(options) == 0 do
    if Node.list() == [],
      do: flash(term, View.only_node()),
      else: pick(term, "/move", [key(term, name)])
  end

  defp apply_command({:move, name, options}, term), do: move_agent(term, name, options)
  defp apply_command({:connect, nil}, term), do: pick(term, "/connect", [])
  defp apply_command({:connect, name}, term), do: connect(term, name)
  defp apply_command({:filter, query}, term), do: filter(term, query)
  defp apply_command(:next, term), do: next_attention(term)
  defp apply_command({:find, query}, term), do: open_search(term, query || "")
  defp apply_command(:tools, term), do: open_tools(term)
  defp apply_command({:copy, what}, term), do: copy_text(term, what)
  defp apply_command({:ask, text}, term), do: ask(term, text)
  defp apply_command({:usage, name}, term), do: append(term, View.usage(Command.find(name)))

  defp apply_command({:unknown, word}, term),
    do: append(term, View.unknown_command(word, Command.suggest(word)))

  # The panel, shown if it was hidden, with the cursor in it; on a narrow
  # terminal that is the overlay.
  defp show_fleet(term), do: term |> assign(sidebar?: true) |> focus_pane("fleet")

  # An agent already running under the key is connected to rather than
  # started again, or, in the background, left alone and named.
  defp spawn_agent(term, name, options, prompt, mode) do
    key = key(term, name)

    case placement(options) do
      {:ok, placement} ->
        case Fleet.whereis(key) do
          nil -> start_agent(term, key, name, placement, prompt, mode)
          pid -> existing_agent(term, key, name, pid, prompt, mode)
        end

      {:error, reason} ->
        append(term, placement_error(reason, "/spawn"))
    end
  end

  defp start_agent(term, key, name, placement, prompt, mode) do
    case Fleet.spawn(key, term.assigns.spawn_opts ++ placement) do
      {:ok, pid} -> started(term, key, name, pid, prompt, mode)
      {:error, reason} -> append(term, fleet_error(reason, placement[:node]))
    end
  end

  defp started(term, key, _name, pid, prompt, :attach),
    do: term |> switch(pid, key) |> append(View.spawned(key)) |> ask_if(prompt)

  defp started(term, key, name, pid, prompt, :background) do
    term
    |> refresh_fleet()
    |> append(View.spawned_background(key, name))
    |> ask_elsewhere(pid, key, prompt)
  end

  defp existing_agent(%{assigns: %{agent_id: key}} = term, key, name, _pid, prompt, mode),
    do: term |> append(View.already_running(key, name, mode)) |> ask_if(prompt)

  defp existing_agent(term, key, name, pid, prompt, :attach),
    do:
      term
      |> switch(pid, key)
      |> append(View.already_running(key, name, :attach))
      |> ask_if(prompt)

  defp existing_agent(term, key, name, pid, prompt, :background),
    do:
      term
      |> append(View.already_running(key, name, :background))
      |> ask_elsewhere(pid, key, prompt)

  defp ask_if(term, nil), do: term
  defp ask_if(term, prompt), do: ask(term, prompt)

  # A prompt for an agent this client is not attached to.
  defp ask_elsewhere(term, _pid, _key, nil), do: term

  defp ask_elsewhere(term, pid, key, prompt) do
    case Agent.ask(pid, prompt) do
      :ok -> append(term, View.sent_to(key, prompt))
      {:error, :not_found} -> append(term, View.no_such_agent(key))
    end
  catch
    :exit, _reason -> append(term, View.unavailable(key))
  end

  # An agent whose turn is running or waiting is not moved until `/confirm`,
  # after what the move would interrupt has been shown.
  defp move_agent(term, name, options) do
    key = key(term, name)

    case placement(options) do
      {:ok, [node: node]} ->
        case Fleet.lookup(key) do
          nil ->
            append(term, View.no_such_agent(key))

          %{status: status} when status in [:running, :parked] ->
            term
            |> assign(confirm: {:move, key, node})
            |> append(View.move_preview(key, node, status))

          _idle ->
            move_now(term, key, node)
        end

      {:error, reason} ->
        append(term, placement_error(reason, "/move"))
    end
  end

  defp move_now(term, key, node) do
    case Fleet.move(key, node) do
      {:ok, pid} -> term |> adopt(key, pid) |> refresh_fleet() |> append(View.moved(key, node))
      {:error, reason} -> append(term, fleet_error(reason, node))
    end
  end

  defp placement_error({:no_such_node, name}, _command),
    do: View.no_such_node(name, [node() | Node.list()])

  defp placement_error({:unknown_options, keys}, command),
    do: View.unknown_options(keys, Command.find(command))

  defp fleet_error({:erpc, reason}, node), do: View.unreachable(node, reason)
  defp fleet_error(reason, _node), do: View.error(reason)

  # The attached agent is addressed by its new process from here on.
  defp adopt(%{assigns: %{agent_id: key}} = term, key, pid), do: reconnect(term, pid)
  defp adopt(term, _key, _pid), do: term

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

  # A name that is an agent's, in this client's scope or as a whole key, is
  # connected to. Otherwise the fleet is searched for it: one agent whose key
  # holds it is the one meant; several are offered to pick from.
  defp connect(term, name) do
    key = key(term, name)

    if key == term.assigns.agent_id or Fleet.whereis(key) != nil do
      connect_key(term, key)
    else
      case matching(name) do
        [] -> append(term, View.no_such_agent(key))
        [member] -> connect_key(term, member.key)
        _several -> pick(term, "/connect", [], String.trim_leading(name, "/"))
      end
    end
  end

  defp matching(name) do
    text = name |> String.trim_leading("/") |> String.downcase()
    Enum.filter(Fleet.list(), &String.contains?(String.downcase(&1.key), text))
  end

  defp connect_key(%{assigns: %{agent_id: key}} = term, key),
    do: append(term, View.connected(key))

  defp connect_key(term, key) do
    case Fleet.whereis(key) do
      nil ->
        append(term, View.no_such_agent(key))

      pid ->
        term |> switch(pid, key) |> append(View.connected(key))
    end
  end

  # Leaves the agent this client is attached to for `pid`, registered under
  # `key`, keeping the view of the one it leaves. The agent is addressed by pid
  # from here on: the registry is eventually consistent, so a key may not yet
  # resolve on this node for an agent that just started on another.
  defp switch(term, pid, key) do
    old = term.assigns.agent_id
    Event.Bus.unsubscribe(old)
    if Map.has_key?(term.assigns.expanded, key), do: Event.Bus.unsubscribe(key)

    term |> keep() |> attach(pid, key) |> refresh_fleet() |> refollow(old, key)
  end

  # A bare name is an agent beside this client's own, under the same org and
  # user; `org/user/name` is any agent in the fleet. A leading slash is
  # tolerated, as is a key nothing holds, which the lookup then reports.
  defp key(term, target) do
    case target |> String.trim_leading("/") |> String.split("/") do
      [name] -> Fleet.key(name, term.assigns.spawn_opts)
      parts -> Enum.join(parts, "/")
    end
  end

  # `/stop NAME` interrupts one agent, and `/stop PREFIX/` every agent under a
  # prefix. Both leave the agents running.
  defp stop(term, target) do
    target = String.trim_leading(target, "/")

    if String.ends_with?(target, "/") do
      append(term, View.stopped_under(target, Fleet.kill(target)))
    else
      key = key(term, target)

      case Agent.interrupt(key) do
        :ok -> append(term, View.stopped(key))
        {:error, :not_found} -> append(term, View.no_such_agent(key))
      end
    end
  end

  # Stops an agent and keeps its store, so `/spawn` brings it back as it was.
  # The attached agent may be shut down; the status row then says so.
  defp shutdown(term, name) do
    key = key(term, name)

    case Fleet.stop(key) do
      :ok -> term |> refresh_fleet() |> append(View.shut_down(key, name))
      {:error, :noproc} -> append(term, View.no_such_agent(key))
      {:error, reason} -> append(term, View.error(reason))
    end
  end

  # Prefix removal always previews exact targets. A single named agent may
  # be removed at once with `--yes`. The attached agent is left out and named.
  defp remove(term, target, confirmed?) do
    target = String.trim_leading(target, "/")
    prefix? = String.ends_with?(target, "/")

    case targets(term, target, prefix?) do
      {[], nil} when prefix? -> append(term, View.nothing_under(target))
      {[], nil} -> append(term, View.no_such_agent(key(term, target)))
      {[], attached} -> append(term, View.attached(attached))
      {keys, _skipped} when confirmed? and not prefix? -> forget_all(term, keys)
      {keys, skipped} -> preview(term, target, keys, skipped)
    end
  end

  defp targets(%{assigns: %{agent_id: attached}}, prefix, true) do
    keys = prefix |> Fleet.list() |> Enum.map(& &1.key)
    {List.delete(keys, attached), if(attached in keys, do: attached)}
  end

  defp targets(%{assigns: %{agent_id: attached}} = term, name, false) do
    key = key(term, name)

    cond do
      key == attached -> {[], attached}
      Fleet.whereis(key) -> {[key], nil}
      true -> {[], nil}
    end
  end

  defp preview(term, target, keys, skipped) do
    term
    |> assign(confirm: {:rm, keys})
    |> append(View.removal_preview(target, keys, skipped))
  end

  defp confirm(%{assigns: %{confirm: {:rm, keys}}} = term) do
    term |> assign(confirm: nil) |> forget_all(keys)
  end

  defp confirm(%{assigns: %{confirm: {:move, key, node}}} = term) do
    term |> assign(confirm: nil) |> move_now(key, node)
  end

  defp confirm(term), do: flash(term, View.nothing_to_confirm())

  defp forget_all(term, keys) do
    {removed, failed} = Enum.split_with(keys, &(Fleet.forget(&1) == :ok))
    term = assign(term, views: Map.drop(term.assigns.views, removed))

    case failed do
      [] -> term |> refresh_fleet() |> append(View.forgotten(keys))
      failed -> term |> refresh_fleet() |> append(View.not_removed(failed))
    end
  end

  # Each call is answered on its own. With one call waiting, a decision with no
  # selector is for it; with several, it has to say which, or `all`.
  defp decide(%{assigns: %{parked: []}} = term, _selector, _decision),
    do: append(term, View.nothing_to_answer())

  defp decide(%{assigns: %{running?: true}} = term, _selector, _decision),
    do: append(term, View.decision_pending())

  defp decide(term, selector, decision) do
    calls = term.assigns.parked

    case chosen(calls, selector) do
      {:ok, chosen} ->
        accept_decision(term, chosen, decision)

      :ambiguous ->
        append(term, View.choose(calls))

      :none ->
        append(term, View.no_such_call(selector))
    end
  end

  defp accept_decision(term, chosen, decision) do
    case Agent.decide(term.assigns.agent, decisions(chosen, decision)) do
      :ok ->
        remaining = term.assigns.parked -- chosen

        term
        |> assign(parked: remaining, running?: true)
        |> append(View.decided(chosen, decision, length(remaining)))

      {:error, _reason} ->
        append(term, View.decision_pending())
    end
  catch
    :exit, _reason ->
      term |> assign(available?: false) |> append(View.unavailable(term.assigns.agent_id))
  end

  defp chosen([only], nil), do: {:ok, [only]}
  defp chosen(_calls, nil), do: :ambiguous
  defp chosen(calls, :all), do: {:ok, calls}

  defp chosen(calls, number) do
    case Integer.parse(number) do
      {n, ""} when n >= 1 and n <= length(calls) -> {:ok, [Enum.at(calls, n - 1)]}
      _other -> :none
    end
  end

  defp decisions(calls, decision),
    do: Map.new(calls, fn {call, _prompt} -> {call.id, decision} end)

  defp ask(%{assigns: %{available?: false, agent_id: key}} = term, _text),
    do: append(term, View.unavailable(key))

  defp ask(term, text) do
    :ok = Agent.ask(term.assigns.agent, text)

    cond do
      term.assigns.running? -> steer(term, text, :running)
      term.assigns.parked != [] -> steer(term, text, :parked)
      true -> question(term, text)
    end
  end

  defp steer(term, text, how) do
    term
    |> assign(queued: term.assigns.queued + 1)
    |> append_lines(["", View.steered(text, how)])
  end

  defp interrupt(term) do
    Agent.interrupt(term.assigns.agent)
    term
  end

  # -- events ----------------------------------------------------------------

  # An event from the attached agent changes state without redrawing; the frame
  # due after it does. One from any other agent, left in the mailbox by a
  # subscription since dropped, changes nothing.
  @impl Breeze.View
  def handle_info(%Event{source: %{agent_id: id}} = event, %{assigns: %{agent_id: id}} = term) do
    term = handle(event, fold(term, event))
    {:noreply, frame_due(term), invalidate: false}
  end

  # A lifecycle event from an agent expanded in the panel.
  def handle_info(%Event{source: %{agent_id: id}} = event, term) do
    case term.assigns.expanded do
      %{^id => %Delegation{} = delegations} ->
        expanded = Map.put(term.assigns.expanded, id, Delegation.fold(delegations, event))
        {:noreply, term |> assign(expanded: expanded) |> frame_due(), invalidate: false}

      _other ->
        {:noreply, term, invalidate: false}
    end
  end

  # The one redraw for everything but a key. A frame that arrives late says
  # the last redraw took longer than the interval, so the interval doubles;
  # one on time halves it back towards the base.
  def handle_info(:frame, term) do
    late = now() - (term.assigns.frame_at || now())

    frame_after =
      if late > div(term.assigns.frame_after, 2),
        do: min(term.assigns.frame_after * 2, @frame_after_most),
        else: max(div(term.assigns.frame_after, 2), @frame_after)

    {:noreply, term |> sync_pane() |> assign(frame_due?: false, frame_after: frame_after)}
  end

  def handle_info({:notice_timeout, ref}, %{assigns: %{notice: {ref, _text}}} = term),
    do: {:noreply, assign(term, notice: nil)}

  def handle_info({:notice_timeout, _stale}, term), do: {:noreply, term, invalidate: false}

  def handle_info({:leader_timeout, ref}, %{assigns: %{leader: {ref, _origin}}} = term),
    do: {:noreply, unlead(term)}

  def handle_info({:leader_timeout, _stale}, term), do: {:noreply, term, invalidate: false}

  def handle_info({:edited, ref, result}, %{assigns: %{editing: {ref, agent_id, _pid}}} = term),
    do: {:noreply, term |> assign(editing: nil) |> sync_pane() |> edited(agent_id, result)}

  def handle_info({:edited, _stale, _result}, term), do: {:noreply, term, invalidate: false}

  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        %{assigns: %{editing: {_edit, _id, pid}}} = term
      )
      when reason != :normal,
      do: {:noreply, term |> assign(editing: nil) |> append(View.editor_failed(reason))}

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
    do: {:noreply, term |> sync_pane() |> refresh_fleet() |> frame_due(), invalidate: false}

  def handle_info(:tick, term) do
    term = assign(term, tick_due?: false)

    if ticking?(term) do
      term = term |> tick() |> sync_pane() |> assign(frame: term.assigns.frame + 1)
      {:noreply, frame_due(term), invalidate: false}
    else
      {:noreply, term, invalidate: false}
    end
  end

  def handle_info({:rewrap, width}, term) do
    {:noreply, assign(term, transcript: Transcript.rewrap(term.assigns.transcript, width))}
  end

  def handle_info(_message, term), do: {:noreply, term}

  defp refresh_fleet(term) do
    fleet = Fleet.list()

    term
    |> assign(fleet: fleet, fleet_due?: false, unseen: unseen(term, fleet))
    |> follow(fleet)
    |> expand_all(fleet)
  end

  # An agent other than the attached one that was running or waiting and is
  # idle now finished a turn this client did not watch; how it ended is kept
  # until the client connects to it. An agent gone from the fleet is dropped.
  defp unseen(%{assigns: %{fleet: previous, unseen: unseen, agent_id: attached}}, fleet) do
    before = Map.new(previous, &{&1.key, &1.status})

    fleet
    |> Enum.reduce(unseen, fn member, unseen ->
      if member.key != attached and member.status == :idle and
           Map.get(before, member.key) in [:running, :parked],
         do: Map.put(unseen, member.key, member.outcome || :ok),
         else: unseen
    end)
    |> Map.take(Enum.map(fleet, & &1.key))
  end

  # -- attention and filtering ------------------------------------------------

  defp attention(%{fleet: fleet, unseen: unseen}),
    do: Enum.filter(fleet, &TarsTUI.Fleet.attention?(&1, unseen))

  # The agents the panel shows: those passing the filter, in key order.
  defp shown(%{fleet: fleet, unseen: unseen, filter: filter}) do
    Enum.filter(fleet, &Filter.match?(filter, &1, TarsTUI.Fleet.attention?(&1, unseen)))
  end

  # The agent needing attention after `key`, round the list, or `nil`.
  defp next_needing(assigns, key) do
    case attention(assigns) do
      [] -> nil
      needing -> Enum.find(needing, hd(needing), &(&1.key > key))
    end
  end

  defp next_attention(term) do
    case next_needing(term.assigns, term.assigns.agent_id) do
      nil -> flash(term, View.nothing_needs_attention())
      member -> connect_key(term, member.key)
    end
  end

  defp highlight_next(term) do
    case next_needing(term.assigns, agent_of(term.assigns.highlighted) || "") do
      nil -> term
      member -> assign(term, highlighted: member.key)
    end
  end

  defp filter(term, nil), do: term |> assign(filter: Filter.none()) |> flash(View.unfiltered())

  defp filter(term, query) do
    case Filter.parse(query) do
      {:ok, filter} ->
        term = assign(term, filter: filter)
        shown = length(shown(term.assigns))
        flash(term, View.filtered(Filter.describe(filter), shown, length(term.assigns.fleet)))

      {:error, word} ->
        flash(term, View.bad_filter(word))
    end
  end

  # `a` in the panel: only the agents needing attention, or every agent again.
  defp toggle_attention(%{assigns: %{filter: %Filter{query: "attention"}}} = term),
    do: assign(term, filter: Filter.none())

  defp toggle_attention(term) do
    {:ok, filter} = Filter.parse("attention")
    assign(term, filter: filter)
  end

  # The attached agent as the fleet has it now. A new process under the same
  # key, after a move or a restart, is adopted; a key the fleet no longer holds
  # means the agent is not running, unless it is a local process that was never
  # in the fleet.
  defp follow(term, fleet) do
    %{agent: agent, agent_id: key} = term.assigns

    case Enum.find(fleet, &(&1.key == key)) do
      nil ->
        assign(term, available?: alive?(agent))

      %{pid: pid} when pid == agent ->
        if term.assigns.available?, do: term, else: reconnect(term, pid)

      %{pid: pid} when is_pid(agent) ->
        term |> reconnect(pid) |> followed(pid)

      %{pid: pid} ->
        assign(term, agent: pid, available?: true)
    end
  end

  defp reconnect(term, pid), do: term |> keep() |> attach(pid, term.assigns.agent_id)

  defp followed(term, pid), do: append(term, View.followed(term.assigns.agent_id, node(pid)))

  defp alive?(pid) when is_pid(pid) and node(pid) == node(), do: Process.alive?(pid)
  defp alive?(_agent), do: false

  defp frame_due(%{assigns: %{frame_due?: true}} = term), do: term

  defp frame_due(%{assigns: %{frame_after: after_ms}} = term) do
    Process.send_after(self(), :frame, after_ms)
    assign(term, frame_due?: true, frame_at: now() + after_ms)
  end

  # A turn starts a fresh tree.
  defp fold(term, %Event{payload: {:turn_started, _questions}} = event) do
    term
    |> assign(
      delegations: Delegation.fold(term.assigns.delegations, event),
      activity: Activity.fold(Activity.new(), event, now: now()),
      trace_id: event.source.trace.trace_id,
      answer: Markdown.new(),
      reasoning: Markdown.new(),
      thinking: "",
      chars: 0,
      answering?: false,
      answer_text: ""
    )
  end

  defp fold(term, event) do
    assign(term,
      activity: Activity.fold(term.assigns.activity, event, now: now()),
      delegations: Delegation.fold(term.assigns.delegations, event)
    )
  end

  # -- turn lifecycle

  defp handle(%Event{payload: {:turn_started, _questions}} = event, term) do
    term
    |> assign(running?: true, parked: [], frame: 0, started_at: now(), queued: 0)
    |> tick()
    |> trace(event)
  end

  # Answered calls leave the parked list, and the turn is running again; what
  # is still parked comes back with the next `:turn_parked`.
  defp handle(%Event{payload: {:turn_resumed, decisions}} = event, term) do
    parked =
      Enum.reject(term.assigns.parked, fn {call, _prompt} -> Map.has_key?(decisions, call.id) end)

    term
    |> assign(running?: true, parked: parked, frame: 0, started_at: now())
    |> tick()
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
        id = call.metadata[:id]

        term
        |> append([indent, Text.truncate(line, max(room, 8))])
        |> assign(tools: Exchange.call(term.assigns.tools, id, call.name, call.arguments))
    end
  end

  defp handle(%Event{payload: {:tool_finished, id, name, result}} = event, term) do
    {output, ok?} =
      case result do
        {:ok, output} -> {output_text(output), true}
        {:error, why} -> {Render.squash(inspect(why)), false}
      end

    term
    |> assign(tools: Exchange.finish(term.assigns.tools, id, name, output, ok?))
    |> trace(event)
  end

  defp handle(%Event{payload: {:tool_denied, id, name, reason}} = event, term) do
    term
    |> assign(tools: Exchange.finish(term.assigns.tools, id, name, reason, false))
    |> trace(event)
  end

  # -- streaming, root span only

  defp handle(%Event{payload: {:result, text}} = event, term) do
    if Event.root?(event) do
      {lines, answer} = Markdown.push(term.assigns.answer, text)

      term
      |> assign(
        answer: answer,
        chars: term.assigns.chars + String.length(text),
        answer_text: term.assigns.answer_text <> text
      )
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
    View.tool_call(name, arguments)
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

    term
    |> answer_lines(answer)
    |> assign(answer: Markdown.new(), reasoning: Markdown.new())
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

  # A tool's result as the inspector shows it: text as it is, anything else as
  # JSON, or as Elixir when it does not encode.
  defp output_text(output) when is_binary(output), do: output

  defp output_text(output) do
    JSON.encode!(output)
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] -> inspect(output)
  end

  # Rows added while the transcript is scrolled up are counted as unread.
  defp append(term, data), do: grow(term, &Transcript.append(&1, data))
  defp append_lines(term, lines), do: grow(term, &Transcript.append_all(&1, lines))

  defp grow(term, fun) do
    before = Transcript.rows(term.assigns.transcript)
    transcript = fun.(term.assigns.transcript)
    added = Transcript.rows(transcript) - before

    unread =
      if pinned?(term) or added == 0, do: term.assigns.unread, else: term.assigns.unread + added

    assign(term, transcript: transcript, unread: unread)
  end

  defp pinned?(term), do: Map.get(implicit_state(term, "log"), :pinned_bottom, true)

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

  defp now, do: System.monotonic_time(:millisecond)
end
