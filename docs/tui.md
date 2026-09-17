# Terminal client

A full-screen terminal client for one agent.

A `Tars.Event.Bus` subscriber holding no conversation state, so several can
watch the same agent. Events are folded as they arrive, and the frame is
redrawn at most every 50 milliseconds while they do, less
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

The panel is `30` columns wide unless started with
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
