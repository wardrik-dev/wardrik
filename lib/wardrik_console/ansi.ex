defmodule WardrikConsole.Ansi do
  @moduledoc """
  `Owl.Data` as chardata for a terminal that does, or does not, take colour.

  `Owl.Data.to_chardata/1` colours text where the node's own standard output
  would take colour, which says nothing about a terminal on the other end of a
  command sent to the node. `chardata/2` is told which it is instead.
  """

  @doc "The text with its styles as escape sequences where `colour?`, and without them where not."
  @spec chardata(Owl.Data.t(), boolean()) :: IO.chardata()
  def chardata(data, false), do: plain(data)
  def chardata(data, true), do: data |> ansi([]) |> IO.ANSI.format(true)

  # Owl.Data.untag/1 leaves a tag inside another tag's list, so every one is
  # taken off here.
  defp plain(%Owl.Tag{data: data}), do: plain(data)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(text), do: text

  # A tag opens its sequences, and on closing resets and opens again those of
  # the tags around it.
  defp ansi(%Owl.Tag{sequences: sequences, data: data}, around) do
    [open(sequences), ansi(data, around ++ sequences), close(sequences), :reset, open(around)]
  end

  defp ansi(list, around) when is_list(list), do: Enum.map(list, &ansi(&1, around))
  defp ansi(text, _around), do: text

  defp open(sequences) do
    Enum.map(sequences, fn
      {:hyperlink, url} -> ["\e]8;;", url, "\e\\"]
      sequence -> sequence
    end)
  end

  # A reset leaves a hyperlink open, so one is closed on its own.
  defp close(sequences), do: for({:hyperlink, _url} <- sequences, do: "\e]8;;\e\\")
end
