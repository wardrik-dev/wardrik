defmodule Tars.TUI.View do
  @moduledoc """
  Pure rendering for `Tars.TUI`.

  Deliberately flat: answers stream out as ordinary text and the only thing
  that ever redraws is a single status line. Nothing here positions anything,
  so a layout problem is a problem with one string rather than with cursor
  arithmetic.

  The verbose trace prints one line per *structural* event — turn boundaries,
  tool calls, metadata. Token-level events (`:chunk`, `:result`, `:thinking`)
  arrive hundreds of times per turn and are accumulated into the status line's
  counters instead, so the trace stays readable at any response length.
  """

  @default_width 100
  @faint [:faint, :light_black]
  @frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  @typedoc "What the status line is drawn from."
  @type status_state() :: %{
          frame: non_neg_integer(),
          thinking: String.t(),
          tools: [{String.t(), :running | :ok | :error}],
          chunks: non_neg_integer(),
          chars: non_neg_integer()
        }

  @doc "The input prompt. Written through the screen, not by `IO.gets/1`."
  @spec prompt() :: Owl.Data.t()
  def prompt, do: ["\n", Owl.Data.tag("› ", [:bright, :cyan])]

  @spec banner(term(), boolean()) :: Owl.Data.t()
  def banner(model, verbose? \\ false) do
    [
      Owl.Data.tag("tars", [:bright, :cyan]),
      Owl.Data.tag(" #{inspect(model)}", @faint),
      if(verbose?, do: Owl.Data.tag("  [verbose]", :yellow), else: ""),
      Owl.Data.tag("\n/quit or ctrl-d to exit\n", @faint)
    ]
  end

  @doc "A streamed piece of the answer — passed through as plain text."
  @spec answer(String.t()) :: Owl.Data.t()
  def answer(text), do: text

  @doc "The spinner frame for a tick count."
  @spec spinner(non_neg_integer()) :: String.t()
  def spinner(frame), do: Enum.at(@frames, rem(frame, length(@frames)))

  @doc """
  The single live line: what the agent is doing right now.

  Tools take precedence over reasoning, and stream volume is appended as
  counters. Everything is clipped to one line, so it can never grow.
  """
  @spec status(status_state(), pos_integer()) :: Owl.Data.t()
  def status(state, width \\ @default_width) do
    # Two columns go to the spinner and its trailing space.
    parts =
      [detail(state, width - 2), counters(state)]
      |> Enum.reject(&(&1 == []))
      |> Enum.intersperse(Owl.Data.tag("  ·  ", @faint))

    [Owl.Data.tag(spinner(state.frame), :cyan), " ", parts]
  end

  @doc """
  One line standing in for a whole stream, once it has finished.

  This is what replaces the hundreds of `chunk`/`result` lines a naive trace
  would print.
  """
  @spec summary(status_state()) :: Owl.Data.t()
  def summary(%{chunks: 0}), do: []

  def summary(state) do
    [
      Owl.Data.tag(String.pad_trailing("stream", 14), :green),
      Owl.Data.tag(counter_text(state), @faint),
      "\n"
    ]
  end

  @spec error(term()) :: Owl.Data.t()
  def error(reason), do: Owl.Data.tag("\n✗ #{inspect(reason)}\n", :red)

  @doc """
  One structural event payload as a trace line.

  Clipped to the terminal width so a large payload cannot wrap into a wall of
  text — the point is the sequence of events, not their full contents.
  """
  @spec event(tuple(), pos_integer()) :: Owl.Data.t()
  def event(event, width \\ @default_width) do
    kind = elem(event, 0)

    [
      Owl.Data.tag(String.pad_trailing(to_string(kind), 14), tag_for_event(kind)),
      Owl.Data.tag(clip(payload(event), width - 16), @faint),
      "\n"
    ]
  end

  @doc """
  Whether an event is worth its own trace line.

  Token-level events are not: they are counted into the status line instead.
  """
  @spec structural?(tuple()) :: boolean()
  def structural?(event), do: elem(event, 0) not in [:chunk, :result, :thinking]

  defp payload({:turn_started, questions}), do: Enum.join(questions, " | ")
  defp payload({:turn_finished, messages}), do: "#{Enum.count(messages)} message(s)"
  defp payload({:turn_failed, reason}), do: inspect(reason)
  defp payload({:tool_started, id, name}), do: "#{name} #{id}"
  defp payload({:tool_finished, id, name, {:ok, _output}}), do: "#{name} #{id} ok"
  defp payload({:tool_finished, id, name, {:error, why}}), do: "#{name} #{id} #{inspect(why)}"
  defp payload({_kind, text}) when is_binary(text), do: inspect(text)
  defp payload({_kind, term}), do: inspect(term)
  defp payload(other), do: inspect(other)

  defp counters(%{chunks: 0}), do: []
  defp counters(state), do: Owl.Data.tag(counter_text(state), @faint)

  defp counter_text(state), do: "#{count(state.chunks)} chunks · #{count(state.chars)} chars"

  defp count(n) when n < 1_000, do: Integer.to_string(n)
  defp count(n) when n < 1_000_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp count(n), do: "#{Float.round(n / 1_000_000, 1)}M"

  defp detail(%{tools: []} = state, width), do: thinking_line(state.thinking, width)

  defp detail(%{tools: tools}, _width) do
    tools
    |> Enum.reverse()
    |> Enum.map(fn {name, status} -> Owl.Data.tag("#{icon(status)} #{name}", tag_for(status)) end)
    |> Enum.intersperse("  ")
  end

  defp thinking_line("", _width), do: Owl.Data.tag("thinking…", @faint)

  defp thinking_line(thinking, width) do
    thinking
    |> last_line()
    |> clip(width)
    |> Owl.Data.tag(@faint)
  end

  # Reasoning is shown one line at a time rather than accumulated, which is
  # what stops it from filling the screen.
  defp last_line(text) do
    text
    |> String.split("\n", trim: true)
    |> List.last()
    |> Kernel.||("thinking…")
  end

  defp clip(text, width) when width > 0 do
    if String.length(text) > width, do: String.slice(text, 0, width - 1) <> "…", else: text
  end

  defp clip(text, _width), do: text

  defp icon(:running), do: "•"
  defp icon(:ok), do: "✓"
  defp icon(:error), do: "✗"

  defp tag_for(:running), do: @faint
  defp tag_for(:ok), do: :green
  defp tag_for(:error), do: :red

  defp tag_for_event(kind) when kind in [:turn_started, :turn_finished], do: :cyan
  defp tag_for_event(:turn_failed), do: :red
  defp tag_for_event(kind) when kind in [:tool_started, :tool_finished], do: :yellow
  defp tag_for_event(:result), do: :green
  defp tag_for_event(_kind), do: @faint
end
