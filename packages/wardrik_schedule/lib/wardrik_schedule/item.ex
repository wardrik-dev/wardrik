defmodule WardrikSchedule.Item do
  @moduledoc """
  One thing a `WardrikSchedule.Source` found: an entry in a feed, a search
  result, a request that arrived. `id` is what tells it apart from the
  source's others, and the rest is what the agent is shown of it.

  `labels` are the `Wardrik.Label`s of what it holds: `"outside"` for
  anything nobody on the agent's side wrote, which every item from the web
  is. The message that asks the agent carries the labels of all its items.
  """

  @enforce_keys [:id]
  defstruct [:id, :title, :link, :at, :text, labels: []]

  @type t() :: %__MODULE__{
          id: String.t(),
          title: String.t() | nil,
          link: String.t() | nil,
          at: DateTime.t() | nil,
          text: String.t() | nil,
          labels: [Wardrik.Label.t()]
        }

  @doc """
  The message that asks the agent: `prompt`, with what each item holds under
  it. Items that hold nothing to show, such as the clock's, add nothing.
  """
  @spec message(String.t(), [t()]) :: String.t()
  def message(prompt, items) when is_binary(prompt) and is_list(items) do
    case Enum.reject(items, &empty?/1) do
      [] -> prompt
      shown -> Enum.join([prompt | Enum.map(shown, &shown/1)], "\n\n")
    end
  end

  @doc "The labels of `items`, together."
  @spec labels([t()]) :: [Wardrik.Label.t()]
  def labels(items), do: Enum.reduce(items, [], &Wardrik.Label.union(&2, &1.labels))

  defp empty?(%__MODULE__{title: nil, link: nil, text: nil}), do: true
  defp empty?(%__MODULE__{}), do: false

  defp shown(%__MODULE__{} = item) do
    [heading(item), item.link, item.text]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp heading(%__MODULE__{title: nil, at: nil}), do: nil
  defp heading(%__MODULE__{title: title, at: nil}), do: "## " <> title
  defp heading(%__MODULE__{title: nil, at: at}), do: "## " <> DateTime.to_iso8601(at)
  defp heading(%__MODULE__{title: title, at: at}), do: "## #{title} (#{DateTime.to_iso8601(at)})"
end
