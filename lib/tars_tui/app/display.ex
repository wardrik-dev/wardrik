defmodule TarsTUI.App.Display do
  @moduledoc "Adapts Breeze assigns and scroll state to the pure conversation projection."
  import Breeze.View, only: [assign: 2]
  alias TarsTUI.App.{Conversation, TermState}

  def apply_event(term, event),
    do: update(term, fn state, opts -> Conversation.apply_event(state, event, opts) end)

  def playback(term, messages),
    do: update(term, fn state, opts -> Conversation.playback(state, messages, opts) end)

  def parked_notice(term, calls),
    do: update(term, fn state, opts -> Conversation.parked_notice(state, calls, opts) end)

  def question(term, text),
    do: update(term, fn state, opts -> Conversation.question(state, text, opts) end)

  def settle(term),
    do: update(term, fn state, opts -> Conversation.settle(state, opts) end)

  def append(term, data),
    do: update(term, fn state, opts -> Conversation.append(state, data, opts) end)

  def append_lines(term, lines),
    do: update(term, fn state, opts -> Conversation.append_lines(state, lines, opts) end)

  defp update(term, fun) do
    opts = [
      now: System.monotonic_time(:millisecond),
      verbose?: term.assigns.verbose?,
      pinned?: Map.get(TermState.implicit_state(term, "log"), :pinned_bottom, true)
    ]

    state = fun.(Conversation.from_assigns(term.assigns), opts)
    assign(term, Conversation.to_assigns(state))
  end
end
