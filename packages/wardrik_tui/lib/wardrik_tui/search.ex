defmodule WardrikTUI.Search do
  @moduledoc """
  A search of the transcript: the text looked for and which of its matches
  is current. Matches are transcript rows, found again on each step so rows
  appended since count.
  """

  alias WardrikTUI.Transcript

  @type t() :: %__MODULE__{query: String.t(), at: non_neg_integer()}

  @enforce_keys [:query]
  defstruct query: "", at: 0

  @doc "A search for `query`, at the match holding `row`, or the first."
  @spec new(String.t(), Transcript.t(), non_neg_integer() | nil) :: t()
  def new(query, transcript, row \\ nil) do
    at =
      transcript
      |> rows(query)
      |> Enum.find_index(&(&1 == row))

    %__MODULE__{query: query, at: at || 0}
  end

  @doc "The rows of `transcript` matching the query."
  @spec rows(Transcript.t(), String.t()) :: [non_neg_integer()]
  def rows(transcript, query), do: transcript |> Transcript.find(query) |> Enum.map(&elem(&1, 0))

  @doc """
  The search moved one match forward or back, round the ends, with the row it
  lands on and how many matches there are; `:none` when nothing matches now.
  """
  @spec step(t(), Transcript.t(), :next | :previous) ::
          {t(), non_neg_integer(), pos_integer()} | :none
  def step(%__MODULE__{} = search, transcript, direction) do
    case rows(transcript, search.query) do
      [] ->
        :none

      rows ->
        count = length(rows)
        delta = if direction == :next, do: 1, else: -1
        at = Integer.mod(search.at + delta, count)
        {%{search | at: at}, Enum.at(rows, at), count}
    end
  end
end
