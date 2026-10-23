defmodule Wardrik.Definitions do
  @moduledoc """
  Keeps each agent's definition in Wardrik's store, as it was put.
  """

  @prefix "definitions/"

  @doc "Keeps `definition` as the agent `id`'s."
  @spec put(Wardrik.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(wardrik, id, definition) do
    with {:ok, _vsn} <- WardrikStore.put(store(wardrik), @prefix <> id, definition), do: :ok
  end

  @doc "Returns the agent `id`'s definition, or `:error` if it has none."
  @spec fetch(Wardrik.t(), String.t()) :: {:ok, map()} | :error
  def fetch(wardrik, id) do
    case WardrikStore.get(store(wardrik), @prefix <> id) do
      nil -> :error
      definition -> {:ok, definition}
    end
  end

  @doc "Removes the agent `id`'s definition. Removing none is `:ok`."
  @spec delete(Wardrik.t(), String.t()) :: :ok | {:error, term()}
  def delete(wardrik, id), do: WardrikStore.delete(store(wardrik), @prefix <> id)

  @doc "Returns the IDs of the agents with a definition."
  @spec ids(Wardrik.t()) :: [String.t()]
  def ids(wardrik) do
    wardrik
    |> store()
    |> WardrikStore.keys(@prefix)
    |> Enum.map(&String.replace_prefix(&1, @prefix, ""))
  end

  defp store(%Wardrik{store: store}), do: WardrikStore.scope(store, "wardrik")
end
