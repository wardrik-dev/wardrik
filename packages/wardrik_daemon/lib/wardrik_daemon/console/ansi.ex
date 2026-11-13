defmodule WardrikDaemon.Console.Ansi do
  @moduledoc false

  @doc "Returns `data` as chardata: with its styles as escape sequences if `colour?`, or plain if not."
  @spec chardata(Owl.Data.t(), boolean()) :: IO.chardata()
  def chardata(data, false), do: plain(data)
  def chardata(data, true), do: IO.ANSI.format(ansi(data, []), true)

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
