defmodule TarsTUI.App do
  # Events are folded as they arrive; the frame is redrawn at most this often
  # while they do.
  @frame_after 20

  @moduledoc """
  A full-screen terminal client for one agent.

  A `Tars.Event.Bus` subscriber holding no conversation state, so several can
  watch the same agent. Events are folded as they arrive and the frame is
  redrawn at most every #{@frame_after} milliseconds while they do, so the frame rate
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

  `/spawn NAME [node=NODE] [prompt]` starts an agent with the same
  `:spawn_opts` this client's own agent was given, on the named node if one is
  given, attaches to it, and sends it the prompt. `/connect NAME` attaches to
  an agent already running, wherever it is. Attaching replays the
  conversation so far: what was asked, what was answered, and each tool call
  with what it returned. Attaching on start works the same way.

  Each agent this client has watched keeps its transcript, scroll position,
  draft and usage, so connecting back restores the place it was left at, and
  messages that arrived meanwhile are replayed under a note. Events are only
  folded for the agent attached now, so a switch mid-stream leaves nothing of
  the previous agent behind.

  When the attached agent comes back under another process, after a move or a
  restart on another node, this client follows it and says so. While it is
  not running at all, the status row says so and nothing typed is sent.

  `/move NAME node=NODE` restarts an agent on another node with the state it
  had. `/stop` interrupts this agent; `/stop NAME` another, and `/stop PREFIX/`
  every agent under a prefix. `/shutdown NAME` stops an agent and keeps its
  conversation for `/spawn` to bring back. `/rm NAME` and `/rm PREFIX/`
  delete agents and their conversations: the first shows exactly what would
  go, and `/confirm` does it. The agent this client is attached to is never
  removed. `/help` lists all of this.

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
  alias Tars.Event
  alias Tars.Fleet
  alias Tars.LLM
  alias TarsTUI.Activity
  alias TarsTUI.Command
  alias TarsTUI.History
  alias TarsTUI.Markdown
  alias TarsTUI.Render
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
    :seen,
    :parked,
    :started_at,
    :frame
  ]

  @default_denial "Denied by the person watching."

  # How long the leader waits for a direction.
  @leader_after 1_500

  @doc """
  Keybindings that work wherever focus is. Pass them as `:global_keybindings`
  when starting the session.

  `Ctrl-X` is the leader: the next `h`, `j`, `k` or `l` moves focus between
  the transcript, the fleet panel and the prompt, `s` stops the turn, and
  `Esc` cancels. `i` in the transcript or the panel focuses the prompt. `Up`
  and `Down` at the prompt's first and last line recall earlier lines, and
  `Ctrl-G` edits the draft in `$VISUAL` or `$EDITOR`. `Ctrl-C` never reaches
  these: Breeze leaves on it.
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
      {"^y", "Approve", &__MODULE__.approve/2},
      {"^n", "Deny", &__MODULE__.deny/2},
      {"^t", "Trace", &__MODULE__.toggle_trace/2},
      {"^f", "Fleet", &__MODULE__.toggle_fleet/2},
      {"^d", "Quit", &__MODULE__.quit/2}
    ]
  end

  @doc false
  def approve(_event, term), do: {:noreply, decide(term, nil, :approve)}

  @doc false
  def deny(_event, term), do: {:noreply, decide(term, nil, {:deny, @default_denial})}

  @doc false
  def toggle_trace(_event, term),
    do: {:noreply, assign(term, verbose?: not term.assigns.verbose?)}

  # Shows or hides the panel. Hiding it while it is focused returns to the
  # prompt.
  @doc false
  def toggle_fleet(_event, %{assigns: %{sidebar?: true}} = term) do
    term = assign(term, sidebar?: false)
    {:noreply, if(term.focused == "fleet", do: focus_pane(term, "prompt"), else: sync_pane(term))}
  end

  def toggle_fleet(_event, term),
    do: {:noreply, term |> assign(sidebar?: true) |> refresh_fleet() |> sync_pane()}

  # A letter goes to the focused pane before any binding sees it, so while the
  # leader waits the prompt is focused and the letter arrives as a change to
  # the draft, where `direction/2` reads it back out. The pane the leader was
  # pressed in is remembered, for the moves and for cancelling.
  @doc false
  def leader(_event, term) do
    ref = make_ref()
    Process.send_after(self(), {:leader_timeout, ref}, @leader_after)
    origin = term.focused || "prompt"

    {:noreply, term |> assign(leader: {ref, origin}, pane: origin) |> focus("prompt")}
  end

  @doc false
  def to_prompt(_event, %{focused: focused} = term) when focused in ["log", "fleet"],
    do: {:noreply, focus_pane(term, "prompt")}

  def to_prompt(_event, _term), do: :continue

  # Cancels a pending leader, or returns to the prompt from another pane. In
  # the prompt, with nothing else to dismiss, it stops the turn, or abandons a
  # parked one; idle, it does nothing.
  @doc false
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
      {{:ask, text}, _line} ->
        assign(term, history: History.push(term.assigns.history, text))

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

  defp edited(term, _agent_id, {:error, reason}), do: append(term, View.editor_failed(reason))

  @doc false
  def connect_highlighted(_event, term) do
    {:noreply, term |> connect_key(term.assigns.highlighted) |> focus_pane("prompt")}
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
        model: Keyword.get(opts, :model, ""),
        verbose?: Keyword.get(opts, :verbose, false),
        editor: Keyword.get(opts, :editor, &TarsTUI.Editor.edit/2),
        views: %{},
        available?: true,
        confirm: nil,
        pane: "prompt",
        leader: nil,
        editing: nil,
        walking: nil,
        commands: History.new(),
        history: History.new(),
        frame: 0,
        frame_due?: false,
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
    |> assign(parked: parked)
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
    unread =
      if Map.get(implicit_state(term, "log"), :pinned_bottom, true),
        do: 0,
        else: term.assigns.unread + length(messages)

    term
    |> assign(unread: unread)
    |> append(View.away(length(messages)))
    |> playback(messages)
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
    append(term, View.tool_result(message.name || "tool", output, tool_ok?(message, output)))
  end

  defp play(_system_message, term), do: term

  defp say(term, ""), do: term

  defp say(term, text) do
    {streamed, answer} = Markdown.push(Markdown.new(), text)
    {rest, _answer} = Markdown.flush(answer)

    term |> assign(answering?: false) |> answer_lines(streamed ++ rest)
  end

  defp calls(term, tool_calls) do
    Enum.reduce(tool_calls, term, fn call, term ->
      %{name: name, arguments: arguments} = ReqLLM.ToolCall.from_map(call)
      append(term, View.tool_call(name, arguments))
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

    assigns =
      assign(assigns,
        source: Transcript.source(assigns.transcript),
        log_height: log_height,
        log_class: log_class(width - side_width, log_height),
        side_width: side_width,
        fleet_rows: fleet_rows(assigns, side_width),
        prompt_class:
          "block w-full h-#{prompt_height} bg-none border-surface focus:border-primary",
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
          <box class="block w-full h-1 overflow-hidden">
            {TarsTUI.Fleet.heading(@fleet, @side_width)}
          </box>
          <box class={"block w-full h-#{@log_height - 1} overflow-hidden "}>
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
        </box>
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
    side = TarsTUI.Fleet.width(assigns.fleet, assigns.agent_id)
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

  defp status(%{available?: false, agent_id: key} = assigns, width) do
    {_org, _user, name} = Fleet.parse(key)

    left =
      Text.tag(
        " ⏻ #{key} is not running · the fleet restarts it if it can · /spawn #{name} brings it back",
        :yellow
      )

    Render.line(Render.justify(left, hints(assigns), width))
  end

  defp status(%{running?: false, parked: [_ | _] = parked} = assigns, width) do
    names = Enum.map_join(parked, ", ", fn {call, _prompt} -> call.name end)
    left = Text.tag(" ? waiting on #{names} · #{decision_keys(parked)}", [:bright, :yellow])
    Render.line(Render.justify(left, hints(assigns), width))
  end

  defp status(%{running?: false} = assigns, width) do
    left = Text.tag(" idle · type a prompt and press Enter", @faint)
    Render.line(Render.justify(left, hints(assigns), width))
  end

  defp status(%{leader: {_ref, _origin}} = assigns, width) do
    span = Activity.innermost(assigns.activity)
    head = [" ", Text.tag(View.spinner(assigns.frame), :cyan), " ", label(span)]
    Render.line(Render.justify(head, hints(assigns), width))
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

  # The keys that matter where focus is, or the directions the leader takes.
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

  defp hints(%{editing: {_ref, _agent_id, _pid}}),
    do: Text.tag("editing the prompt · the screen returns when the editor closes ", :yellow)

  defp hints(%{pane: "log"}),
    do: Text.tag("j/k scroll · Ctrl-U/D half page · i prompt · Esc back ", @faint)

  defp hints(%{pane: "fleet"}),
    do: Text.tag("j/k move · Enter connect · i prompt · Esc back ", @faint)

  defp hints(%{available?: false}),
    do: Text.tag("Ctrl-X pane · Ctrl-F fleet · Ctrl-D quit ", @faint)

  defp hints(%{parked: [_ | _]}), do: Text.tag("Esc abandon · Ctrl-D quit ", @faint)
  defp hints(_assigns), do: Text.tag("Ctrl-X pane · Ctrl-F fleet · Ctrl-D quit ", @faint)

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
    unread = if assigns.unread > 0, do: "#{assigns.unread} unread · End to follow · ", else: ""
    right = Text.tag(unread <> queued(assigns), @faint)
    Render.line(Render.justify(left, right, width))
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

  def handle_event("ask", %{value: value}, term) do
    command = Command.parse(value, term.assigns.parked != [])
    term = term |> assign(draft: "", leader: nil) |> reset("prompt") |> remember(value, command)

    case command do
      :quit -> {:stop, term}
      command -> {:noreply, apply_command(command, term)}
    end
  end

  def handle_event(_name, _event, term), do: {:noreply, term}

  defp apply_command(:blank, term), do: term
  defp apply_command(:confirm, term), do: confirm(term)

  # Anything but `/confirm` drops a removal that was waiting on it.
  defp apply_command(command, %{assigns: %{confirm: pending}} = term) when pending != nil do
    apply_command(command, term |> assign(confirm: nil) |> append(View.cancelled()))
  end

  defp apply_command({:stop, nil}, term), do: interrupt(term)
  defp apply_command({:stop, target}, term), do: stop(term, target)
  defp apply_command({:shutdown, name}, term), do: shutdown(term, name)
  defp apply_command({:rm, target, confirmed?}, term), do: remove(term, target, confirmed?)
  defp apply_command({:approve, selector}, term), do: decide(term, selector, :approve)
  defp apply_command(:fleet, term), do: list_fleet(term)
  defp apply_command(:help, term), do: append_lines(term, [""] ++ View.help())

  defp apply_command({:deny, selector, reason}, term),
    do: decide(term, selector, {:deny, reason || @default_denial})

  defp apply_command({:spawn, name, options, prompt}, term),
    do: spawn_agent(term, name, options, prompt)

  defp apply_command({:move, name, options}, term), do: move_agent(term, name, options)
  defp apply_command({:connect, name}, term), do: connect(term, name)
  defp apply_command({:ask, text}, term), do: ask(term, text)
  defp apply_command({:usage, name}, term), do: append(term, View.usage(Command.find(name)))

  defp apply_command({:unknown, word}, term),
    do: append(term, View.unknown_command(word, Command.suggest(word)))

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
         {:ok, pid} <- Fleet.move(key, node) do
      term |> adopt(key, pid) |> refresh_fleet() |> append(View.moved(key, node))
    else
      {:ok, []} -> append(term, View.error(:node_required))
      {:error, reason} -> append(term, View.error(reason))
    end
  end

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

  defp connect(term, name), do: connect_key(term, key(term, name))

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
    Event.Bus.unsubscribe(term.assigns.agent_id)

    term |> keep() |> attach(pid, key) |> refresh_fleet()
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

  defp confirm(term), do: append(term, View.nothing_to_confirm())

  defp forget_all(term, keys) do
    {removed, failed} = Enum.split_with(keys, &(Fleet.forget(&1) == :ok))
    term = assign(term, views: Map.drop(term.assigns.views, removed))

    case failed do
      [] -> term |> refresh_fleet() |> append(View.forgotten(keys))
      failed -> term |> refresh_fleet() |> append(View.error({:not_removed, failed}))
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

  def handle_info(%Event{}, term), do: {:noreply, term, invalidate: false}

  def handle_info(:frame, term), do: {:noreply, term |> sync_pane() |> assign(frame_due?: false)}

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

  def handle_info(:refresh_fleet, term), do: {:noreply, term |> sync_pane() |> refresh_fleet()}

  def handle_info(:tick, %{assigns: %{running?: true}} = term) do
    schedule_tick()
    {:noreply, term |> sync_pane() |> assign(frame: term.assigns.frame + 1)}
  end

  def handle_info(:tick, term), do: {:noreply, term}

  def handle_info({:rewrap, width}, term) do
    {:noreply, assign(term, transcript: Transcript.rewrap(term.assigns.transcript, width))}
  end

  def handle_info(_message, term), do: {:noreply, term}

  defp refresh_fleet(term) do
    fleet = Fleet.list()
    term |> assign(fleet: fleet, fleet_due?: false) |> follow(fleet)
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

  defp frame_due(term) do
    Process.send_after(self(), :frame, @frame_after)
    assign(term, frame_due?: true)
  end

  # A turn starts a fresh tree.
  defp fold(term, %Event{payload: {:turn_started, _questions}} = event) do
    term
    |> assign(
      activity: Activity.fold(Activity.new(), event, now: now()),
      trace_id: event.source.trace.trace_id,
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

  # Answered calls leave the parked list, and the turn is running again; what
  # is still parked comes back with the next `:turn_parked`.
  defp handle(%Event{payload: {:turn_resumed, decisions}} = event, term) do
    schedule_tick()

    parked =
      Enum.reject(term.assigns.parked, fn {call, _prompt} -> Map.has_key?(decisions, call.id) end)

    term
    |> assign(running?: true, parked: parked, frame: 0, started_at: now())
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
