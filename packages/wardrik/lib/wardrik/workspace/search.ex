defmodule Wardrik.Workspace.Search do
  @moduledoc """
  Finds the files that best answer a query in plain words, best first.

      Wardrik.Workspace.Search.search(files, "pumpkin loaf launch", limit: 5)
      #=> [%{path: "digests/C1.md", line: 12, excerpt: "...", at: ~U[...], score: 4.2, file: file}]

    * Each file is cut into passages at blank lines. A file scores by its best passage, and its hit
      quotes that passage.
    * Any word of the query counts. Passages with more of its words, or rarer ones, rank first.
      See `Wardrik.Workspace.Search.BM25`.
    * Words match whole, singular or plural: "posts" finds "post". Another form of a word, as
      "posted", or another word that means the same, doesn't match.
    * A newer file ranks a little higher than an older one that matches as well.
  """

  alias Wardrik.Workspace.File
  alias Wardrik.Workspace.Search.BM25

  @excerpt_bytes 600
  @longest_passage 40
  @half_life_days 30

  @type hit() :: %{
          path: String.t(),
          line: pos_integer(),
          excerpt: String.t(),
          at: DateTime.t() | nil,
          score: float(),
          file: File.t()
        }

  @doc """
  Returns up to `:limit` hits for `query` among `files`, given as `{path, file}`, best first.
  Returns `{:error, message}` for a query with no words to search for.

  ## Options

    * `:limit` - the most hits. `5` unless set.
    * `:now` - the time recency counts from. Now unless set.
  """
  @spec search([{String.t(), File.t()}], String.t(), keyword()) ::
          {:ok, [hit()]} | {:error, String.t()}
  def search(files, query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case BM25.terms(query) do
      [] ->
        {:error, "#{inspect(query)} has no words to search for"}

      terms ->
        passages =
          for {path, file} <- files, passage <- passages(file.content), do: {path, file, passage}

        scores =
          BM25.score(terms, Enum.map(passages, fn {_path, _file, passage} -> passage.terms end))

        hits =
          passages
          |> Enum.zip(scores)
          |> Enum.filter(fn {_passage, score} -> score > 0 end)
          |> Enum.group_by(fn {{path, _file, _passage}, _score} -> path end)
          |> Enum.map(fn {_path, scored} -> hit(Enum.max_by(scored, &elem(&1, 1)), now) end)
          |> Enum.sort_by(& &1.score, :desc)
          |> Enum.take(limit)

        {:ok, hits}
    end
  end

  @doc "Returns `hit` as the protocol's JSON, without its file."
  @spec json(hit()) :: map()
  def json(hit) do
    %{
      "path" => hit.path,
      "line" => hit.line,
      "excerpt" => hit.excerpt,
      "at" => hit.at && DateTime.to_iso8601(hit.at),
      "score" => hit.score
    }
  end

  defp hit({{path, file, passage}, score}, now) do
    %{
      path: path,
      line: passage.line,
      excerpt: excerpt(passage.text),
      at: file.at,
      score: Float.round(score * recency(file.at, now), 3),
      file: file
    }
  end

  # A passage is a run of lines between blank ones, cut where it grows too long to quote.
  defp passages(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.chunk_by(fn {line, _number} -> String.trim(line) == "" end)
    |> Enum.reject(fn [{line, _number} | _rest] -> String.trim(line) == "" end)
    |> Enum.flat_map(&Enum.chunk_every(&1, @longest_passage))
    |> Enum.map(fn [{_line, first} | _rest] = lines ->
      text = Enum.map_join(lines, "\n", &elem(&1, 0))
      %{line: first, text: text, terms: BM25.terms(text)}
    end)
  end

  defp excerpt(text) when byte_size(text) <= @excerpt_bytes, do: text

  defp excerpt(text) do
    cut = binary_part(text, 0, @excerpt_bytes)
    String.replace_invalid(cut, "") <> "…"
  end

  # A gentle tie-breaker: a file written today counts a quarter more than one long past.
  defp recency(nil, _now), do: 1.0

  defp recency(at, now) do
    days = max(DateTime.diff(now, at, :second), 0) / 86_400
    1.0 + 0.25 * :math.pow(0.5, days / @half_life_days)
  end
end
