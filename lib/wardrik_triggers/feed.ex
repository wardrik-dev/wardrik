defmodule WardrikTriggers.Feed do
  @moduledoc false

  @behaviour Saxy.Handler

  @shown 20
  @remembered 500
  @summary 500

  @type entry() :: %{
          id: String.t(),
          title: String.t() | nil,
          link: String.t() | nil,
          date: String.t() | nil,
          summary: String.t() | nil
        }

  @entries ~w(item entry)
  @fields %{
    "title" => :title,
    "link" => :link,
    "guid" => :id,
    "id" => :id,
    "pubDate" => :date,
    "published" => :date,
    "updated" => :date,
    "description" => :summary,
    "summary" => :summary,
    "content" => :summary
  }

  @doc "Parses the entries of an RSS or Atom feed, in feed order."
  @spec parse(String.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def parse(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{entries: [], entry: nil, field: nil}) do
      {:ok, entries} -> {:ok, entries}
      {:error, error} -> {:error, "the feed doesn't read: #{Exception.message(error)}"}
    end
  end

  @doc """
  Returns the entries not in `seen`, oldest first, and the updated `seen`.

  The updated `seen` keeps the newest #{@remembered} ids.
  """
  @spec unseen([entry()], [String.t()]) :: {[entry()], [String.t()]}
  def unseen(entries, seen) do
    known = MapSet.new(seen)
    new = entries |> Enum.reject(&MapSet.member?(known, &1.id)) |> Enum.reverse()
    {new, Enum.take(Enum.map(Enum.reverse(new), & &1.id) ++ seen, @remembered)}
  end

  @doc "Appends up to #{@shown} entries to `prompt`, and a count of the rest."
  @spec prompt(String.t(), [entry()]) :: String.t()
  def prompt(prompt, entries) do
    {shown, rest} = Enum.split(entries, @shown)
    more = if rest == [], do: [], else: ["And #{length(rest)} more."]
    Enum.join([prompt | Enum.map(shown, &described/1)] ++ more, "\n\n")
  end

  @impl Saxy.Handler
  def handle_event(:start_element, {name, _attributes}, state) when name in @entries,
    do: {:ok, %{state | entry: %{id: nil, title: nil, link: nil, date: nil, summary: nil}}}

  def handle_event(:start_element, {"link", attributes}, %{entry: %{} = entry} = state) do
    case List.keyfind(attributes, "href", 0) do
      {"href", href} -> {:ok, %{state | entry: %{entry | link: entry.link || href}}}
      nil -> {:ok, %{state | field: :link}}
    end
  end

  def handle_event(:start_element, {name, _attributes}, %{entry: %{}} = state),
    do: {:ok, %{state | field: Map.get(@fields, name)}}

  def handle_event(:characters, text, %{entry: %{} = entry, field: field} = state)
      when not is_nil(field),
      do: {:ok, %{state | entry: Map.update!(entry, field, &((&1 || "") <> text))}}

  def handle_event(:cdata, text, state), do: handle_event(:characters, text, state)

  def handle_event(:end_element, name, %{entry: %{} = entry} = state) when name in @entries,
    do: {:ok, %{state | entries: [identified(entry) | state.entries], entry: nil, field: nil}}

  def handle_event(:end_element, _name, state), do: {:ok, %{state | field: nil}}
  def handle_event(:end_document, _data, state), do: {:ok, Enum.reverse(state.entries)}
  def handle_event(_event, _data, state), do: {:ok, state}

  defp identified(entry) do
    entry = Map.new(entry, fn {key, value} -> {key, trimmed(value)} end)
    %{entry | id: entry.id || entry.link || entry.title}
  end

  defp trimmed(nil), do: nil
  defp trimmed(text), do: String.trim(text)

  defp described(entry) do
    [
      entry.title,
      entry.link,
      entry.date,
      entry.summary && String.slice(entry.summary, 0, @summary)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
