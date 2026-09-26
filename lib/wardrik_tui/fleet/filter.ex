defmodule WardrikTUI.Fleet.Filter do
  @moduledoc """
  Which agents the fleet panel shows, from a query typed as `/filter QUERY`.

  A query is words separated by spaces, every one of which must match:

  | Word | Matches agents |
  | --- | --- |
  | `TEXT` | whose key contains the text |
  | `name:TEXT` | whose name contains the text |
  | `org:TEXT`, `user:TEXT` | in that org or for that user; `_` means none |
  | `node:TEXT` | on a node whose name contains the text |
  | `status:idle`, `status:running`, `status:parked` | doing that |
  | `attention` | needing attention |

  Matching ignores case. An empty query matches everything.
  """

  alias Wardrik.Fleet.Member

  @typedoc "One word of a query."
  @type term_() ::
          {:key, String.t()}
          | {:name, String.t()}
          | {:org, String.t()}
          | {:user, String.t()}
          | {:node, String.t()}
          | {:status, Member.status()}
          | :attention

  @type t() :: %__MODULE__{query: String.t(), terms: [term_()]}

  defstruct query: "", terms: []

  @doc "No filter."
  @spec none() :: t()
  def none, do: %__MODULE__{}

  @doc "Whether the filter lets everything through."
  @spec none?(t()) :: boolean()
  def none?(%__MODULE__{terms: []}), do: true
  def none?(%__MODULE__{}), do: false

  @doc "Reads a query. `{:error, word}` names the first word that is not one of the table's."
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(query) when is_binary(query) do
    words = query |> String.trim() |> String.split(~r/\s+/, trim: true)

    case Enum.reduce_while(words, [], &collect/2) do
      {:error, word} -> {:error, word}
      terms -> {:ok, %__MODULE__{query: Enum.join(words, " "), terms: Enum.reverse(terms)}}
    end
  end

  defp collect(word, terms) do
    case term(String.downcase(word)) do
      {:error, _word} = error -> {:halt, error}
      term -> {:cont, [term | terms]}
    end
  end

  defp term("attention"), do: :attention
  defp term("name:" <> text) when text != "", do: {:name, text}
  defp term("org:" <> text) when text != "", do: {:org, text}
  defp term("user:" <> text) when text != "", do: {:user, text}
  defp term("node:" <> text) when text != "", do: {:node, text}
  defp term("status:idle"), do: {:status, :idle}
  defp term("status:running"), do: {:status, :running}
  defp term("status:parked"), do: {:status, :parked}
  defp term("status:" <> _other = word), do: {:error, word}

  defp term(word) when word != "",
    do: if(String.contains?(word, ":"), do: {:error, word}, else: {:key, word})

  @doc "Whether `member` passes, given whether it needs attention."
  @spec match?(t(), Member.t(), boolean()) :: boolean()
  def match?(%__MODULE__{terms: terms}, %Member{} = member, attention?) do
    Enum.all?(terms, &matches?(&1, member, attention?))
  end

  defp matches?(:attention, _member, attention?), do: attention?
  defp matches?({:key, text}, member, _), do: contains?(member.key, text)
  defp matches?({:name, text}, member, _), do: contains?(member.name, text)
  defp matches?({:org, text}, member, _), do: scope?(member.org, text)
  defp matches?({:user, text}, member, _), do: scope?(member.user, text)
  defp matches?({:node, text}, member, _), do: contains?(Atom.to_string(member.node), text)
  defp matches?({:status, status}, member, _), do: member.status == status

  defp scope?(nil, text), do: text == "_"
  defp scope?(value, text), do: String.downcase(value) == text

  defp contains?(value, text), do: String.contains?(String.downcase(value), text)

  @doc "The query as typed, normalised to single spaces."
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{query: query}), do: query
end
