# Maintaining the terminal client

`TarsTUI.App` is the Breeze root view. It owns the terminal session's callbacks,
key routing, screen layout, and decisions about when to redraw. It runs in the
same process as before; extracting a module does not introduce another process.

| Module | Responsibility |
| --- | --- |
| `Components.Chrome` | Header, activity/status row, prompt hints, usage footer |
| `Components.FleetPanel` | Fleet and delegation rows, sidebar and overlay layout |
| `Components.Palette` | Palette box, sizing, and choice presentation |
| `Components.Inspector` | Scrollable tool and delegation details |
| `App.Conversation` | Explicit display-state struct, event reduction, replay, streamed markdown, tool exchanges |
| `App.Display` | Adapts Breeze assigns and scroll state to conversation operations |
| `App.Connection` | Attach/switch/reconnect, subscriptions, fleet snapshots, saved agent views |
| `App.PaletteFlow` | Choice generation and argument collection; returns actions for App to execute |
| `App.Commands` | Shared prompt/palette command execution, fleet operations, confirmations |
| `App.Prompt` | Draft history and external-editor integration |
| `App.Interaction` | Focus, overlays, search navigation, filtering, clipboard, notices |
| `App.Frames` | Coalesced frame and activity-tick scheduling |
| `App.TermState` | Terminal dimensions and implicit widget-state access |

## State and event flow

The active display lives in Breeze assigns. `App.Display` reads its conversation
fields into `%App.Conversation{}`, applies a pure operation, and writes only those
fields back. Saved per-agent views use that struct directly, including the prompt
cursor and transcript scroll state. There is no second cached copy of the active
conversation state.

Conversation operations receive the current monotonic time, tracing preference,
and whether the transcript is pinned to its bottom. They do not subscribe, send
messages, schedule timers, or access a terminal. The current agent snapshot owns
identity and live status; restoring a saved display cannot overwrite those with
stale values. Generation changes discard the saved view.

App routes events for the attached agent to the conversation reducer. Events for
other expanded agents update their delegation trees; other late events are
ignored. These updates return `invalidate: false` and schedule a shared frame.
Keys still redraw immediately. Keep that distinction when adding handlers.

`PaletteFlow.select/3` returns a next step, command line, or navigation action.
App applies focus and overlay changes. Both palette commands and typed commands
then enter `Commands.run_line/2`, preserving parsing, history, and confirmation
behavior in one place.

## Components and widgets

Components use `Breeze.Component` and explicit attributes. Import their functions
and call them with `<.function .../>`; Breeze 0.5.1 does not resolve remote
`<Module.function>` tags as components. It also omits dynamic `false` and `nil`
attributes, so optional attributes need defaults. App loads the component modules
before the first render so Breeze can apply those defaults.

Function components own presentation. The existing Palette and Scroll implicits
continue to own widget-local input and scrolling; named events return to App.
Keep IDs and event names stable when moving template fragments, because focus,
saved widget state, and tests depend on them.

## Verification

The existing Breeze integration tests exercise the complete view, including
agent switching, stale events, editor completion, focus, resizing, and command
confirmation. Pure conversation and palette-flow tests cover the new boundaries
without a terminal process. Run `mix precommit` for all required test, coverage,
complexity, type, duplication, and reachability checks.
