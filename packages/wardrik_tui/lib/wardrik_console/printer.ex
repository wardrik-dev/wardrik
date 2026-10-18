defmodule WardrikConsole.Printer do
  @moduledoc """
  An agent's events as the lines a terminal shows, each written once and never
  redrawn.

  `event/2` takes one `Wardrik.Event` and returns the lines it completed, in
  order, as `Owl.Data`:

      printer = WardrikConsole.Printer.new(width: 100)
      {lines, printer} = WardrikConsole.Printer.event(printer, event)

  The answer and the reasoning arrive as markdown, and a line of either is
  returned once its newline has, so nothing is shown that could still change.
  A markdown table is laid out at the printer's width once it ends. Reasoning
  is faint, behind a bar. Only the turn's own text is shown, not the text of
  work it delegated.

  A tool call is a line when it starts and another when it finishes or is
  refused, cut to the width, as are a model call asked again after it failed
  and history being compacted. What the answer and the reasoning had not
  finished comes first, so the lines keep the order things happened in. A
  turn that ends, fails, is stopped, or waits on a person returns what is
  left of its text, then says so, and why it failed is written whole. Every
  other event returns no lines.
  """

  alias Wardrik.Event
  alias WardrikConsole.Markdown
  alias WardrikConsole.Table

  @typedoc "The width lines are laid out to, and the answer and reasoning not yet returned."
  @type t() :: %__MODULE__{
          width: pos_integer(),
          answer: Markdown.t(),
          reasoning: Markdown.t()
        }

  defstruct width: 80, answer: %Markdown{}, reasoning: %Markdown{}

  @faint [:faint, :light_black]

  @doc "A printer laying lines out to `:width` columns, 80 unless given."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: %__MODULE__{width: Keyword.get(opts, :width, 80)}

  @doc "The lines `event` completes, and the printer to give the next event to."
  @spec event(t(), Event.t()) :: {[Owl.Data.t()], t()}
  def event(%__MODULE__{} = printer, %Event{payload: %Event.Result{text: text}} = event) do
    if Event.root?(event) do
      {settled, printer} = settle(printer, :reasoning)
      {lines, answer} = Markdown.push(printer.answer, text)
      {settled ++ answer(lines, printer), %{printer | answer: answer}}
    else
      {[], printer}
    end
  end

  def event(%__MODULE__{} = printer, %Event{payload: %Event.Thinking{text: text}} = event) do
    if Event.root?(event) do
      {settled, printer} = settle(printer, :answer)
      {lines, reasoning} = Markdown.push(printer.reasoning, text)
      {settled ++ reasoning(lines, printer), %{printer | reasoning: reasoning}}
    else
      {[], printer}
    end
  end

  def event(%__MODULE__{} = printer, %Event{payload: payload}) do
    case said(payload) do
      nil ->
        {[], printer}

      lines ->
        {settled, printer} = settle(printer)
        {settled ++ Enum.map(lines, &fitted(&1, printer.width)), printer}
    end
  end

  # A tool's line is cut to the width, so a long call stays one line. A turn's
  # own ending is written whole, since why it failed is worth wrapping for.
  defp fitted({:cut, line}, width), do: Owl.Data.truncate(line, width)
  defp fitted(line, _width), do: line

  # The lines an event says, before which the text so far is settled; `nil`
  # for an event that neither says anything nor settles.
  defp said(%Event.ToolStarted{name: name, arguments: arguments}),
    do: [{:cut, ["  ", Owl.Data.tag("→", :cyan), " ", name, arguments(arguments)]}]

  defp said(%Event.ToolFinished{name: name, result: {:ok, _output}}),
    do: [{:cut, ["  ", Owl.Data.tag("✓", :green), " ", name]}]

  defp said(%Event.ToolFinished{name: name, result: {:error, reason}}),
    do: [{:cut, ["  ", Owl.Data.tag("✗", :red), " ", name, ": ", inspect(reason)]}]

  defp said(%Event.ToolDenied{name: name, reason: reason}),
    do: [{:cut, ["  ", Owl.Data.tag("✗", :red), " ", name, " was refused: ", reason]}]

  defp said(%Event.ModelRetrying{} = retry) do
    again = ", again in #{ceil(retry.wait_ms / 1_000)}s (#{retry.attempt} of #{retry.attempts})"
    [{:cut, ["  ", Owl.Data.tag("↻", :yellow), " model failed: ", inspect(retry.reason), again]}]
  end

  # Every other span is a tool call's, or work inside one, which the call's own
  # lines already say.
  defp said(%Event.SpanStarted{name: "compacting history" = name}),
    do: [{:cut, ["  ", Owl.Data.tag("·", :cyan), " ", name]}]

  defp said(%Event.TurnParked{calls: calls}) do
    [
      Owl.Data.tag("Waiting on a person for #{count(calls)}:", [:bright, :yellow])
      | for({call, prompt} <- calls, do: {:cut, ["  ? ", call.name, "  ", call.id, "  ", prompt]})
    ]
  end

  defp said(%Event.TurnFinished{}), do: []

  defp said(%Event.TurnFailed{reason: reason}),
    do: [Owl.Data.tag("✗ the turn failed: #{inspect(reason)}", :red)]

  defp said(%Event.TurnInterrupted{}), do: [Owl.Data.tag("■ stopped", :yellow)]
  defp said(_payload), do: nil

  defp arguments(arguments) when map_size(arguments) == 0, do: []
  defp arguments(arguments), do: Owl.Data.tag([" ", JSON.encode!(arguments)], @faint)

  defp count([_only]), do: "1 call"
  defp count(calls), do: "#{length(calls)} calls"

  # The unfinished text of the answer and the reasoning, or of one of them.
  defp settle(printer) do
    {reasoning, printer} = settle(printer, :reasoning)
    {answer, printer} = settle(printer, :answer)
    {reasoning ++ answer, printer}
  end

  defp settle(printer, :answer) do
    {lines, _answer} = Markdown.flush(printer.answer)
    {answer(lines, printer), %{printer | answer: Markdown.new()}}
  end

  defp settle(printer, :reasoning) do
    {lines, _reasoning} = Markdown.flush(printer.reasoning)
    {reasoning(lines, printer), %{printer | reasoning: Markdown.new()}}
  end

  defp answer(lines, printer), do: Enum.flat_map(lines, &laid_out(&1, printer.width))

  defp reasoning(lines, printer) do
    lines
    |> Enum.flat_map(&laid_out(&1, printer.width - 2))
    |> Enum.map(&Owl.Data.tag(["┊ ", &1], @faint))
  end

  defp laid_out(%Table{} = table, width), do: Table.lines(table, max(width, 2))
  defp laid_out(line, _width), do: [line]
end
