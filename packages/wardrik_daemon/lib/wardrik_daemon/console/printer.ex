defmodule WardrikDaemon.Console.Printer do
  @moduledoc false

  alias WardrikDaemon.Console.Markdown
  alias WardrikDaemon.Console.Table

  defstruct width: 80, answer: %Markdown{}, reasoning: %Markdown{}, thinking?: false

  @type t() :: %__MODULE__{
          width: pos_integer(),
          answer: Markdown.t(),
          reasoning: Markdown.t(),
          thinking?: boolean()
        }

  @faint [:faint, :light_black]

  @doc "Returns a printer that lays lines out to `:width` columns. `80` unless set."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: %__MODULE__{width: Keyword.get(opts, :width, 80)}

  @doc "Returns the lines `event` completes, and the printer for the next event."
  @spec event(t(), map()) :: {[Owl.Data.t()], t()}
  def event(printer, %{"type" => "wardrik.message.delta", "data" => %{"delta" => text}}) do
    {settled, printer} = settle(printer, :reasoning)
    {lines, answer} = Markdown.push(printer.answer, text)
    {settled ++ answer(lines, printer), %{printer | answer: answer}}
  end

  def event(printer, %{"type" => "wardrik.reasoning.delta", "data" => %{"delta" => text}}) do
    {settled, printer} = settle(printer, :answer)
    {lines, reasoning} = Markdown.push(printer.reasoning, text)
    {thought, printer} = thought(lines, %{printer | reasoning: reasoning})
    {settled ++ thought, printer}
  end

  def event(printer, %{"type" => "wardrik." <> type, "data" => data}) do
    case said(type, data) do
      nil ->
        {[], printer}

      lines ->
        {settled, printer} = settle(printer)
        {settled ++ Enum.map(lines, &fitted(&1, printer.width)), printer}
    end
  end

  def event(printer, _event), do: {[], printer}

  defp fitted({:cut, line}, width), do: Owl.Data.truncate(line, width)
  defp fitted(line, _width), do: line

  defp said("message.created", %{"message" => message} = data),
    do: [{:cut, [Owl.Data.tag("› ", :cyan), sender(data["sender"]), text(message)]}]

  defp said("tool_call.started", %{"tool" => tool}),
    do: [{:cut, ["  ", Owl.Data.tag("→", :cyan), " ", tool["name"], arguments(tool)]}]

  defp said("tool_call.completed", %{"tool" => tool, "status" => "ok"}),
    do: [{:cut, ["  ", Owl.Data.tag("✓", :green), " ", tool["name"]]}]

  defp said("tool_call.completed", %{"tool" => tool} = data),
    do: [{:cut, ["  ", Owl.Data.tag("✗", :red), " ", tool["name"], ": ", why(data["error"])]}]

  defp said("tool_call.denied", %{"tool" => tool, "reason" => reason}),
    do: [{:cut, ["  ", Owl.Data.tag("✗", :red), " ", tool["name"], " was refused: ", reason]}]

  defp said("message.retrying", data) do
    again =
      ", again in #{ceil(data["wait_ms"] / 1_000)}s (#{data["attempt"]} of #{data["attempts"]})"

    [{:cut, ["  ", Owl.Data.tag("↻", :yellow), " model failed: ", why(data["error"]), again]}]
  end

  defp said("conversation.compacted", data) do
    counts = "#{data["messages_before"]} messages to #{data["messages_after"]}"
    [{:cut, ["  ", Owl.Data.tag("·", :cyan), " compacted the history, ", counts]}]
  end

  defp said("run.interrupted", %{"interrupts" => interrupts}) do
    [
      Owl.Data.tag("Waiting on a person for #{count(interrupts)}:", [:bright, :yellow])
      | Enum.map(interrupts, &waiting/1)
    ]
  end

  defp said("run.completed", _data), do: []

  defp said("run.failed", data),
    do: [Owl.Data.tag("✗ the turn failed: #{why(data["error"])}", :red)]

  defp said("run.cancelled", _data), do: [Owl.Data.tag("■ stopped", :yellow)]

  defp said("run.deadline_exceeded", _data),
    do: [Owl.Data.tag("■ stopped: it ran past its timeout", :yellow)]

  defp said(_type, _data), do: nil

  defp waiting(interrupt) do
    name = interrupt["name"] || "the model"
    {:cut, ["  ? ", name, "  ", interrupt["id"], "  ", interrupt["message"], held(interrupt)]}
  end

  defp held(%{"labels" => [_label | _labels]}),
    do: Owl.Data.tag("  (after content from outside)", :yellow)

  defp held(_interrupt), do: []

  defp sender(%{"id" => id}), do: Owl.Data.tag(id <> ": ", @faint)
  defp sender(_sender), do: []

  defp text(%{"parts" => parts}),
    do: for(%{"type" => "text", "content" => content} <- parts, do: content) |> Enum.join(" ")

  defp text(_message), do: ""

  defp arguments(%{"call" => %{"arguments" => arguments}}) when map_size(arguments) > 0,
    do: Owl.Data.tag([" ", JSON.encode!(arguments)], @faint)

  defp arguments(_tool), do: []

  defp why(%{"message" => message}), do: message
  defp why(reason), do: inspect(reason)

  defp count([_only]), do: "1 call"
  defp count(calls), do: "#{length(calls)} calls"

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
    {thought, printer} = thought(lines, %{printer | reasoning: Markdown.new()})
    closed = if printer.thinking?, do: [""], else: []
    {thought ++ closed, %{printer | thinking?: false}}
  end

  # A line of space sets a run of reasoning off from what's around it.
  defp thought(lines, printer) do
    case reasoning(lines, printer) do
      [_line | _lines] = thought when not printer.thinking? ->
        {["" | thought], %{printer | thinking?: true}}

      thought ->
        {thought, printer}
    end
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
