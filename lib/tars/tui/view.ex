defmodule Tars.TUI.View do
  @moduledoc """
  Pure rendering for `Tars.TUI`.

  Prose is written once and never redrawn, and nothing wraps it: the terminal
  soft-wraps it and a resize reflows it correctly.

  Structured rows are clipped instead. A span line is a label rather than
  prose, and the tree only reads as a tree while each node occupies one row —
  a fan-out branch named after a paragraph would otherwise take five. The
  status line is clipped for a harder reason: it is overwritten in place, and
  one that reaches the right margin wraps and then scrolls.

  The span tree is indentation rather than a drawn block. A span prints one
  line when it opens and one when it closes, each indented by its depth, so the
  shape of a turn is legible in scrollback without anything being repainted.
  """

  alias Tars.TUI.Activity

  @default_width 100
  @faint [:faint, :light_black]
  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @typedoc "What the status line is drawn from."
  @type status_state() :: %{
          frame: non_neg_integer(),
          activity: Activity.t(),
          thinking: String.t(),
          chars: non_neg_integer(),
          now: integer()
        }

  @doc "The input prompt. Written through the screen, not by `IO.gets/1`."
  @spec prompt() :: Owl.Data.t()
  def prompt, do: ["\n", Owl.Data.tag("› ", [:bright, :cyan])]

  @spec banner(term(), boolean(), String.t()) :: Owl.Data.t()
  def banner(model, verbose? \\ false, geometry \\ "") do
    [
      Owl.Data.tag("tars", [:bright, :cyan]),
      Owl.Data.tag(" #{inspect(model)}", @faint),
      Owl.Data.tag(" #{geometry}", @faint),
      if(verbose?, do: Owl.Data.tag("  [verbose]", :yellow), else: ""),
      Owl.Data.tag("\n/quit or ctrl-d to exit\n", @faint)
    ]
  end

  @doc "The spinner frame for a tick count."
  @spec spinner(non_neg_integer()) :: String.t()
  def spinner(frame), do: Enum.at(@frames, rem(frame, length(@frames)))

  @doc """
  One line of the answer, already rendered by `Tars.TUI.Markdown`.
  """
  @spec answer(Owl.Data.t()) :: Owl.Data.t()
  def answer(line), do: [line, "\n"]

  @doc """
  A line typed while a turn was running, echoed so it is visibly accepted.

  Nothing else marks a steering message: it joins the turn in flight rather
  than starting one, so without this the transcript shows no sign of it until
  the turn it changed comes back.
  """
  @spec steer(String.t(), pos_integer()) :: Owl.Data.t()
  def steer(text, width \\ @default_width) do
    row = [Owl.Data.tag("» ", [:bright, :cyan]), text]

    [Owl.Data.truncate(row, room(width)), "\n"]
  end

  @doc "One line of the model's reasoning, for a transcript that wants it."
  @spec reasoning(Owl.Data.t()) :: Owl.Data.t()
  def reasoning(line), do: [Owl.Data.tag(["┊ ", line], @faint), "\n"]

  @doc """
  One span as a line of the tree, indented by `depth`.

  A running span shows no time; a settled one shows what it took and how it
  went. Clipped to one row, whatever it was named.
  """
  @spec span(Activity.span(), non_neg_integer(), integer(), pos_integer()) :: Owl.Data.t()
  def span(span, depth, now, width \\ @default_width) do
    indent = String.duplicate("  ", depth)

    row = [
      Owl.Data.tag([glyph(span), " ", span.name || "?"], colour(span)),
      cause(span),
      took(span, now)
    ]

    [indent, Owl.Data.truncate(row, room(width - String.length(indent))), "\n"]
  end

  @doc "A low-level event as a trace line, or `nil` when it is not worth one."
  @spec trace(tuple()) :: Owl.Data.t() | nil
  def trace({:model_started, model_spec}),
    do: line("model", inspect(model_spec), :cyan)

  def trace({:model_finished, :ok, ms}),
    do: line("model", "ok #{seconds(ms)}", :cyan)

  def trace({:model_finished, {:error, reason}, ms}),
    do: line("model", "#{inspect(reason)} #{seconds(ms)}", :red)

  def trace({:meta, meta}), do: line("meta", inspect(meta), @faint)
  def trace({:tool_started, id, name}), do: line("tool", "#{name} #{id}", :yellow)

  def trace({:tool_finished, id, name, {:ok, _output}}),
    do: line("tool", "#{name} #{id} ok", :yellow)

  def trace({:tool_finished, id, name, {:error, why}}),
    do: line("tool", "#{name} #{id} #{inspect(why)}", :red)

  def trace({:turn_started, questions}), do: line("turn", Enum.join(questions, " | "), :cyan)
  def trace({:turn_finished, messages}), do: line("turn", "#{length(messages)} message(s)", :cyan)

  def trace({:turn_interrupted, stats}),
    do: line("turn", "interrupted #{inspect(stats)}", :yellow)

  def trace(_payload), do: nil

  @doc "What an interrupt stopped, so a kill switch is never silent."
  @spec interrupted(map()) :: Owl.Data.t()
  def interrupted(stats) do
    [Owl.Data.tag(["\n■ stopped", detail(stats), "\n"], :yellow)]
  end

  defp detail(%{resolution: :idle}), do: " · nothing was running"

  defp detail(stats) do
    [
      " · ",
      seconds(stats.elapsed_ms),
      if(stats.resolution == :killed, do: " · killed", else: ""),
      dropped(stats.dropped)
    ]
  end

  defp dropped(0), do: ""
  defp dropped(1), do: " · 1 queued message dropped"
  defp dropped(n), do: " · #{n} queued messages dropped"

  @spec error(term()) :: Owl.Data.t()
  def error(reason), do: Owl.Data.tag("\n✗ #{inspect(reason)}\n", :red)

  @doc """
  The single live line: what the agent is doing right now.

  Clipped, never wrapped. Names the innermost running span, because the deepest
  work in flight is the most specific answer to "what is it doing".
  """
  @spec status(status_state(), pos_integer()) :: Owl.Data.t()
  def status(state, width \\ @default_width) do
    parts =
      [doing(state, width), counters(state)]
      |> Enum.reject(&(&1 == []))
      |> Enum.intersperse(Owl.Data.tag("  ·  ", @faint))

    [Owl.Data.tag(spinner(state.frame), :cyan), " ", Owl.Data.truncate(parts, room(width))]
  end

  defp doing(%{activity: activity} = state, width) do
    case Activity.innermost(activity) do
      nil ->
        Owl.Data.tag("working", @faint)

      span ->
        label = label(span)
        elapsed = Owl.Data.tag(" #{elapsed(span, state)}", @faint)

        room =
          width - 2 - Owl.Data.length(label) - Owl.Data.length(elapsed) - counters_room(state)

        [label, detail(span, state, room), elapsed]
    end
  end

  # Two columns go to the spinner and its trailing space, and one is left
  # spare: a line that reaches the right margin wraps, and a wrapped status
  # line scrolls instead of being overwritten.
  defp room(width), do: max(width - 3, 1)

  defp counters_room(state) do
    case counters(state) do
      [] -> 0
      data -> Owl.Data.length(data) + Owl.Data.length("  ·  ")
    end
  end

  defp label(%{name: nil}), do: Owl.Data.tag("working", @faint)
  defp label(%{name: name}), do: Owl.Data.tag(name, :cyan)

  defp detail(%{doing: nil}, _state, _room), do: []
  defp detail(%{doing: "thinking"}, state, room), do: thinking(state.thinking, room)
  defp detail(%{doing: doing}, _state, _room), do: Owl.Data.tag(" · #{doing}", @faint)

  defp thinking("", _room), do: Owl.Data.tag(" · thinking", @faint)

  defp thinking(text, room) do
    Owl.Data.tag(" · #{tail(text, max(room - 3, 8))}", @faint)
  end

  # The newest words, not the oldest: reasoning runs to hundreds of characters
  # with no newline in it, and clipping the far end freezes the line on the
  # first few words while the thought moves on.
  defp tail(text, width) do
    case String.length(text) - width do
      over when over > 0 -> String.slice(text, over, width)
      _fits -> text
    end
  end

  defp elapsed(span, %{now: now}), do: seconds(Activity.elapsed_ms(span, now))

  defp counters(%{chars: 0}), do: []
  defp counters(%{chars: chars}), do: Owl.Data.tag("#{count(chars)} chars", @faint)

  defp line(kind, detail, tag) do
    [
      Owl.Data.tag(String.pad_trailing(kind, 6), tag),
      Owl.Data.tag(detail, @faint),
      "\n"
    ]
  end

  defp glyph(%{status: :running}), do: "·"
  defp glyph(%{status: :ok}), do: "✓"
  defp glyph(%{status: :error}), do: "✗"

  defp colour(%{status: :running}), do: @faint
  defp colour(%{status: :ok}), do: :green
  defp colour(%{status: :error}), do: :red

  defp cause(%{error: nil}), do: []
  defp cause(%{error: reason}), do: Owl.Data.tag(" · #{inspect(reason)}", :red)

  defp took(%{status: :running}, _now), do: []
  defp took(span, now), do: Owl.Data.tag(" · #{seconds(Activity.elapsed_ms(span, now))}", @faint)

  defp seconds(ms) when ms < 1_000, do: "#{ms}ms"
  defp seconds(ms), do: "#{Float.round(ms / 1_000, 1)}s"

  defp count(n) when n < 1_000, do: Integer.to_string(n)
  defp count(n) when n < 1_000_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp count(n), do: "#{Float.round(n / 1_000_000, 1)}M"
end
