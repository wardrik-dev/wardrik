defmodule WardrikDaemon.CLI.Table do
  @moduledoc false

  alias WardrikDaemon.CLI.Context

  @doc "Writes `answer` as JSON if the command was given `--json`, or prints `table` as `print/2` does."
  @spec show(Context.t(), term(), table()) :: :ok
  def show(cx, answer, table), do: Context.show(cx, answer, fn _answer -> print(cx, table) end)

  @typedoc "A table's `:header`, its `:rows`, and what to say if there are none, `:empty`."
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
    rows = Enum.map(rows, fn row -> Enum.map(row, &to_string(&1 || "")) end)
    widths = Enum.zip_with([header | rows], &widest/1)
    Context.puts(cx, Owl.Data.tag(line(header, widths), [:faint, :light_black]))
    Enum.each(rows, &Context.puts(cx, line(&1, widths)))
  end

  @doc "Prints `pairs` of a label and a value, one a line. Leaves out those with no value."
  @spec pairs(Context.t(), [{String.t(), term()}]) :: :ok
  def pairs(cx, pairs) do
    shown = for {label, value} <- pairs, value not in [nil, "", []], do: {label, to_string(value)}

    width =
      shown |> Enum.map(fn {label, _value} -> String.length(label) end) |> Enum.max(fn -> 0 end)

    Enum.each(shown, fn {label, value} ->
      Context.puts(cx, [
        Owl.Data.tag(String.pad_trailing(label, width), :light_black),
        "  ",
        value
      ])
    end)
  end

  defp widest(column), do: column |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)

  defp line(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
    |> String.trim_trailing()
  end
end
