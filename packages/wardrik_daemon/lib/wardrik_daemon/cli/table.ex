defmodule WardrikDaemon.CLI.Table do
  @moduledoc false

  alias WardrikDaemon.CLI.Context

  @doc "Writes `answer` as JSON if the command was given `--json`, or prints `table` as `print/2` does."
  @spec show(Context.t(), term(), table()) :: :ok
  def show(cx, answer, table), do: Context.show(cx, answer, fn _answer -> print(cx, table) end)

  @typedoc """
  A table's `:header`, its `:rows`, and what to say if there are none, `:empty`. A cell is a
  value, or `{value, style}` to show it in a colour, as `{"parked", :yellow}`.
  """
  @type table() :: [header: [String.t()], rows: [[term()]], empty: String.t()]

  @doc """
  Prints `:rows` under `:header`, or `:empty` if there are none.

      Table.print(cx, header: ["NODE", "AGENTS"], rows: [["box1", 3]], empty: "No nodes answer.")
  """
  @spec print(Context.t(), table()) :: :ok
  def print(cx, table) do
    case Keyword.fetch!(table, :rows) do
      [] -> Context.puts(cx, Owl.Data.tag(Keyword.fetch!(table, :empty), :light_black))
      rows -> printed(cx, Keyword.fetch!(table, :header), rows)
    end
  end

  defp printed(cx, header, rows) do
    rows = Enum.map(rows, fn row -> Enum.map(row, &cell/1) end)
    widths = Enum.zip_with([Enum.map(header, &{&1, nil}) | rows], &widest/1)

    Context.puts(
      cx,
      Owl.Data.tag(line(Enum.map(header, &{&1, nil}), widths), [:faint, :light_black])
    )

    Enum.each(rows, &Context.puts(cx, line(&1, widths)))
  end

  defp cell({value, style}), do: {to_string(value || ""), style}
  defp cell(value), do: {to_string(value || ""), nil}

  @doc "Prints `pairs` of a label and a value, one a line. Leaves out those with no value."
  @spec pairs(Context.t(), [{String.t(), term()}]) :: :ok
  def pairs(cx, pairs) do
    shown = for {label, value} <- pairs, value not in [nil, "", []], do: {label, to_string(value)}

    width =
      shown
      |> Enum.map(fn {label, _value} -> String.length(label) end)
      |> Enum.max(fn -> 0 end)

    Enum.each(shown, fn {label, value} ->
      Context.puts(cx, [
        Owl.Data.tag(String.pad_trailing(label, width), :light_black),
        "  ",
        value
      ])
    end)
  end

  defp widest(column) do
    column
    |> Enum.map(fn {text, _style} -> String.length(text) end)
    |> Enum.max(fn -> 0 end)
  end

  # Padded as text, so a colour never shifts the columns. The last cell isn't padded.
  defp line(row, widths) do
    {last, cells} = List.pop_at(Enum.zip(row, widths), -1)

    padded =
      for {{text, style}, width} <- cells,
          do: [styled(String.pad_trailing(text, width), style), "  "]

    {{text, style}, _width} = last
    [padded, styled(text, style)]
  end

  defp styled(text, nil), do: text
  defp styled(text, style), do: Owl.Data.tag(text, style)
end
