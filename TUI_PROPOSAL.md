# Proposal: a keyboard-first Tars fleet TUI

Status: proposed; ready for review. This document does not authorize or implement the changes below.

## Context

This branch adds fleet management to Tars. `TarsTUI.App` currently presents a transcript, composer, and fleet sidebar. Users can spawn, connect, move, and delete agents through slash commands. The next step is making this feel like a cohesive terminal workspace: fast pane navigation, prompt history, external editing, discoverable commands, and visibility into delegated work across the fleet.

The existing foundation is useful: throttled streaming redraws, scrollback that stops following new output, multiline input, visible focus, `Tab` pane cycling, and `j`/`k` navigation in both the transcript and fleet list. Preserve these behaviors.

This proposal follows a code review of `lib/tars_tui/`, fleet/agent state, and the installed Breeze input implementation. `mix test test/tars_tui` passed all 176 tests during that review. Findings below are code-based; a live multi-node terminal session has not been evaluated.

## Priority 0 — make agent context and actions dependable

Complete these before layering more navigation and command surfaces onto the app.

### 1. Preserve context when switching agents

Maintain per-agent view state: draft and cursor, transcript position, follow-output state, expanded activity, and unread results. Switching away and back should restore the user's place.

Current attachment rebuilds the transcript from conversation messages and omits tool exchanges. Model and usage are initialized at mount and are not refreshed on attachment. Define the scope of displayed usage explicitly—turn, agent, or client session—and show the attached agent's actual model. Preserve tool/activity history where available; distinguish cached history from information that cannot currently be reconstructed.

Implementation entry points: `TarsTUI.App.attach/3`, `switch/3`, `playback/2`, `TarsTUI.Usage`.

### 2. Handle movement, disconnection, and late events

After a switch, the client addresses the agent by PID. The move handler currently discards the replacement PID, so moving that agent can leave the client addressing the old process. Reattach after movement and expose reconnecting/unavailable states after restarts or node loss.

Filter incoming events by the active agent identity, with turn identity where necessary. Unsubscribing does not remove events already in the mailbox; the current event handler accepts every `Tars.Event`.

### 3. Make consequential command behavior explicit

- Separate interrupting a turn, stopping an agent while retaining its conversation, and deleting the agent's stored history. The backend already provides `Fleet.stop/1` and `Fleet.forget/1`; `/kill` currently deletes history.
- Before bulk deletion, resolve and display exact targets and explain what will be removed. Decide how the attached agent is handled explicitly.
- Allow approval of individual parked calls. The current approval handler applies one decision to every parked call; approving all should be an explicit action showing the count.
- Fix the composer label for prompts sent during a run. The UI calls them queued, but `Tars.Agent.State.queue/2` asks the running turn to stop at its next boundary. Describe this as steering. A separate queue-after-completion action would require backend support.

Acceptance: switch A → B → A without losing drafts or position; keep usage correctly attributed; move the attached agent and successfully send its next prompt; reject late events from a previous attachment; make deletion scope and approval scope unambiguous.

## Priority 1 — deliver the everyday keyboard workflow

### 4. Introduce consistent, configurable keybindings

Use focus-aware bindings and a configurable leader for pane/workspace actions. Suggested default leader: `Ctrl+X`. Avoid defaulting to tmux's `Ctrl+B`, since users may run Tars inside tmux.

| Action | Proposed default |
| --- | --- |
| Command palette | `Ctrl+P` |
| Edit draft in external editor | `Ctrl+G` |
| Prompt history | Up/Down at first/last logical input line |
| Search prompt history | `Ctrl+R` |
| Cycle panes | `Tab` / `Shift+Tab` |
| Directional pane focus | Leader, then `h/j/k/l` |
| Transcript/fleet movement | `j/k`, arrows |
| Transcript start/end | `gg` / `G`, Home/End |
| Transcript half-page | `Ctrl+U` / `Ctrl+D`, scoped to transcript |
| Focus composer from a navigation pane | `i` |
| Dismiss overlay or return from navigation | `Esc` |
| Interrupt attached agent | Leader, then `s`; `/stop` alias |
| Quit client | `/quit` and palette action |

Show a brief shortcut guide after the leader and contextual hints for the focused pane. Full Vim editing is not required for this pass.

`Esc` currently interrupts globally; change this before introducing overlays. Overlay keys must take precedence over workspace actions. Separate focusing the fleet from toggling its visibility; current `Ctrl+F` behavior conflates them. Changing `Ctrl+D` from global quit also requires updating help and onboarding.

Do not default to global Ctrl+H/J/K/L: the installed composer uses Ctrl+J for newline and handles Ctrl+H as deletion. Retain multiline input and ordinary text editing.

### 5. Add history and external editing

History should preserve multiline cursor movement: Up enters history only at the first logical line, and Down past the newest entry restores the unfinished draft. Start with per-agent prompt history and separate command history. Offer cross-agent search explicitly, showing the originating agent. Selecting history never sends it automatically. Decide persistence and retention separately from basic navigation.

`Ctrl+G` should open the draft using `$VISUAL`, falling back to `$EDITOR`. Return edited text to the same agent without sending it. Preserve the original draft on editor launch failure. Properly hand off terminal input/output and restore rendering, focus, and terminal state on exit; verify the necessary Breeze lifecycle support before implementation.

Label the composer with its recipient and send behavior, for example: `Prompt → researcher · Running · Enter steers at next boundary`.

### 6. Add the command palette and one command registry

Build a fuzzy-filtered `Ctrl+P` modal with recent actions, contextual availability, shortcuts, and explicit action targets. Actions needing arguments should open agent/node pickers; destructive actions should open a target preview. Opening and dismissing the palette must preserve draft and focus.

Define commands once: identifier, label, aliases, argument schema, availability, shortcut, and handler. Generate palette entries, slash completion, and help from that registry. These are currently maintained separately in the app and view modules.

Acceptance: complete compose → history recall → external edit → palette action → agent switch entirely by keyboard, with no unintended sends, interruptions, or lost drafts. Verify behavior inside tmux as well as directly in a terminal.

## Priority 2 — make fleet activity inspectable

### 7. Add delegation summaries and inspection

Important domain constraint: `Tars.Subagent.run/3` performs bounded work in its parent's event stream. A delegate is not necessarily a registered fleet agent, and unnamed delegation may reuse an existing span. Counting spans is therefore not a reliable subagent count.

Introduce explicit delegation identity/type and lifecycle metadata. Publish compact per-agent summaries for fleet display, and load detailed activity when an agent is expanded. Provide a snapshot mechanism so a client attaching mid-run sees work already underway. Do not require every client to subscribe to every agent's raw token stream.

Suggested presentation:

```text
Fleet · 6 agents · 2 need attention

› research   running   sub 2/4   +1
    ├ pricing          searching
    └ competitors      thinking
  reviewer   approval  1
  writer     idle      new result
  analyst    idle      last run failed
```

Here `sub 2/4` means two active delegations of four started this turn; `+1` means one pending prompt. Define nested-delegation counting explicitly. Keep live status separate from last outcome and distinguish delegated work from independently addressable fleet agents.

Use `h/l` to collapse/expand. Enter on an agent connects; Enter on a delegation opens an inspector with its task, activity, outcome, and available output. Do not imply independent messaging or cancellation unless the backend supports it.

Implementation entry points: `Tars.Subagent`, `Tars.Event`, `TarsTUI.Activity`, `Tars.Agent.State.meta/1`, `Tars.Fleet.Member`, `TarsTUI.Fleet`.

### 8. Add attention and fleet filtering

- Show approval counts, unseen completions, and failures for agents not currently attached.
- Add a next-attention action and filters for name, node, status, and org/user scope.
- Show full identity when short names are ambiguous.
- Keep rows stable while navigating; use an explicit attention filter instead of automatically reordering them under the cursor.
- Use a stable, configurable sidebar width. Current content-dependent sizing can rewrap the transcript as rows change.
- On narrow terminals, open fleet as an overlay instead of making it inaccessible when the sidebar disappears.

Acceptance: discover and inspect another agent's delegated work without interrupting the current one; attach mid-run and see an accurate summary; notice an off-screen approval or failure; navigate reliably while fleet state changes.

## Priority 3 — complete command and transcript polish

### 9. Refine slash-command UX

| Current command/behavior | Proposed behavior |
| --- | --- |
| `/fleet` prints a static list | Open/focus the interactive fleet browser |
| `/connect NAME` | With no argument, open a picker; complete names and disambiguate identity |
| `/spawn` always attaches | Offer background creation; distinguish creation from connection to an existing agent |
| `/move NAME node=N` | Offer a node picker and explain restart/active-work consequences |
| Unknown slash command becomes a prompt | Show suggestions; provide an explicit way to submit literal slash-prefixed text |
| `/help` appends to transcript | Open searchable help with contextual bindings |

Preserve prompt text in parsing. The current `/spawn` parser collapses whitespace and interprets leading `key=value` words as options; `/move` discards trailing free text. Support an explicit prompt delimiter, for example `/spawn researcher node=tars_b -- Investigate x=y`, and reject unexpected arguments. Keep invalid command input available for correction. Replace raw inspected errors with actionable messages.

### 10. Improve transcript inspection and feedback

Add transcript search, expandable tool results, copy-answer/code actions, and a visible `new output below · End to follow` indicator. Use brief notices for local UI actions instead of filling the conversation with help and fleet listings. Keep focus and status understandable without relying solely on color.

## Delivery and review guidance

Implement in the priority order above, using small changes with focused verification. Priority 0 is prerequisite work; the keybinding model and command registry should precede the palette and additional overlays. Delegation indicators depend on backend metadata/snapshots, not just rendering changes.

Review these decisions before implementation:

1. Accept `Ctrl+X` as leader and migrate global Esc/Ctrl+D behavior, or choose another consistent map?
2. Keep current steering semantics with accurate labeling, or also add a true queue-only action?
3. What are the scopes and persistence requirements for drafts, history, usage, and unread state?
4. What delegation identity and snapshot contract can the backend provide, including nested work and late attachment?
5. What naming and compatibility policy should distinguish interrupt, stop, and permanent deletion?

Extend existing tests for state preservation, input routing, command validation, event identity, and lifecycle transitions. Add representative terminal checks for narrow layouts, multiline editing, editor handoff, and tmux. Existing test success establishes a baseline, not coverage of these proposed workflows.
