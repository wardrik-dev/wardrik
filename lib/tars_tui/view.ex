defmodule TarsTUI.View do
  @moduledoc """
  Pure rendering for `TarsTUI.App`.

  Prose is written once and never redrawn, and nothing wraps it: the terminal
  soft-wraps it and a resize reflows it correctly.

  Structured rows are clipped instead. A span line is a label rather than
  prose, and the tree only reads as a tree while each node occupies one row —
  a fan-out branch named after a paragraph would otherwise take five.

  The span tree is indentation rather than a drawn block. A span prints one
  line when it opens and one when it closes, each indented by its depth, so the
  shape of a turn is legible in scrollback without anything being repainted.
  """

  alias TarsTUI.Activity
  alias TarsTUI.Text

  @default_width 100
  @faint [:faint, :light_black]
  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @doc "The spinner frame for a tick count."
  @spec spinner(non_neg_integer()) :: String.t()
  def spinner(frame), do: Enum.at(@frames, rem(frame, length(@frames)))

  @doc "One line of the model's reasoning, for a transcript that wants it."
  @spec reasoning(Text.t()) :: Text.t()
  def reasoning(line), do: [Text.tag(["┊ ", line], @faint), "\n"]

  @doc """
  One span as a line of the tree, indented by `depth`.

  A running span shows no time; a settled one shows what it took and how it
  went. Clipped to one row, whatever it was named.
  """
  @spec span(Activity.span(), non_neg_integer(), integer(), pos_integer()) :: Text.t()
  def span(span, depth, now, width \\ @default_width) do
    indent = String.duplicate("  ", depth)

    row = [
      Text.tag([glyph(span), " ", span.name || "?"], colour(span)),
      cause(span),
      took(span, now)
    ]

    [indent, Text.truncate(row, room(width - String.length(indent))), "\n"]
  end

  @doc "A low-level event as a trace line, or `nil` when it is not worth one."
  @spec trace(tuple()) :: Text.t() | nil
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
  @spec interrupted(map()) :: Text.t()
  def interrupted(stats) do
    [Text.tag(["\n■ stopped", detail(stats), "\n"], :yellow)]
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

  @spec error(term()) :: Text.t()
  def error(reason), do: Text.tag("\n✗ #{inspect(reason)}\n", :red)

  # Two columns go to the glyph and its trailing space, and one is left spare.
  defp room(width), do: max(width - 3, 1)

  defp line(kind, detail, tag) do
    [
      Text.tag(String.pad_trailing(kind, 6), tag),
      Text.tag(detail, @faint),
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
  defp cause(%{error: reason}), do: Text.tag(" · #{inspect(reason)}", :red)

  defp took(%{status: :running}, _now), do: []
  defp took(span, now), do: Text.tag(" · #{seconds(Activity.elapsed_ms(span, now))}", @faint)

  defp seconds(ms) when ms < 1_000, do: "#{ms}ms"
  defp seconds(ms), do: "#{Float.round(ms / 1_000, 1)}s"
end
