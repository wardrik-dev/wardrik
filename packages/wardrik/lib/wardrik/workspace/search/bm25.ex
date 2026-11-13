defmodule Wardrik.Workspace.Search.BM25 do
  @moduledoc """
  Okapi BM25: how well each passage answers a query's terms, counting how often each term appears
  in it, how rare the term is across all passages, and how long the passage is.

      terms = Wardrik.Workspace.Search.BM25.terms("Pumpkin loaves are back")
      #=> ["pumpkin", "loave", "back"]

      Wardrik.Workspace.Search.BM25.score(terms, [["pumpkin", "loave"], ["rye"]])
      #=> [1.2199390377855037, 0.0]
  """

  @k1 1.2
  @b 0.75

  @stop ~w(a an and are as at be but by for from had has have he her his i if in into is it its
           me my no not of on or our she so that the their them they this to us was we were what
           when where which who will with you your)

  @doc """
  Returns the terms of `text`: its words, lowercased, without common words, and plurals made
  singular.
  """
  @spec terms(String.t()) :: [String.t()]
  def terms(text) do
    ~r/[\p{L}\p{N}]+/u
    |> Regex.scan(String.downcase(text))
    |> Enum.map(fn [word] -> word end)
    |> Enum.reject(&(&1 in @stop))
    |> Enum.map(&stem/1)
  end

  @doc "Returns each passage's score for `query`, in the passages' order. `0.0` matches nothing."
  @spec score([String.t()], [[String.t()]]) :: [float()]
  def score(_query, []), do: []

  def score(query, passages) do
    count = length(passages)
    average = Enum.sum_by(passages, &length/1) / count
    query = Enum.uniq(query)
    frequencies = Enum.map(passages, &Enum.frequencies/1)

    rarity =
      Map.new(query, fn term ->
        holding = Enum.count(frequencies, &Map.has_key?(&1, term))
        {term, :math.log(1 + (count - holding + 0.5) / (holding + 0.5))}
      end)

    for {passage, frequency} <- Enum.zip(passages, frequencies) do
      norm = @k1 * (1 - @b + @b * length(passage) / max(average, 1))
      Enum.sum_by(query, &term_score(Map.get(frequency, &1, 0), rarity[&1], norm))
    end
  end

  defp term_score(0, _rarity, _norm), do: 0.0
  defp term_score(times, rarity, norm), do: rarity * times * (@k1 + 1) / (times + norm)

  # Harman's S-stemmer: plurals only, as "posts" to "post" and "stories" to "story".
  defp stem(word) do
    cond do
      String.ends_with?(word, "ies") and not String.ends_with?(word, ["eies", "aies"]) ->
        String.replace_suffix(word, "ies", "y")

      String.ends_with?(word, "es") and not String.ends_with?(word, ["aes", "ees", "oes"]) ->
        String.replace_suffix(word, "es", "e")

      String.ends_with?(word, "s") and not String.ends_with?(word, ["us", "ss"]) ->
        String.replace_suffix(word, "s", "")

      true ->
        word
    end
  end
end
