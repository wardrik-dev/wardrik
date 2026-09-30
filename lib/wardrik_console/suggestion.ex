defmodule WardrikConsole.Suggestion do
  @moduledoc """
  The names closest to a word that names none of them, for saying what was
  probably meant.

      WardrikConsole.Suggestion.closest("stauts", ["status", "stop", "start"])
      #=> ["status", "start"]
  """

  @doc "Up to three of `names` near enough to `word`, nearest first."
  @spec closest(String.t(), [String.t()]) :: [String.t()]
  def closest(word, names) when is_binary(word) and is_list(names) do
    names
    |> Enum.map(&{String.jaro_distance(&1, word), &1})
    |> Enum.filter(fn {distance, _name} -> distance >= 0.75 end)
    |> Enum.sort(:desc)
    |> Enum.map(&elem(&1, 1))
    |> Enum.take(3)
  end
end
