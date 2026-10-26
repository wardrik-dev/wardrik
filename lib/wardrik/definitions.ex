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

  @doc "Removes the agent `id`'s definition, and its boundary. Removing none is `:ok`."
  @spec delete(Wardrik.t(), String.t()) :: :ok | {:error, term()}
  def delete(wardrik, id) do
    with :ok <- WardrikStore.delete(store(wardrik), @prefix <> id),
         do: WardrikStore.delete(store(wardrik), "boundaries/" <> id)
  end

  @doc "Keeps the policy named `name` as the agent `id`'s boundary: the token that defined it named it."
  @spec put_boundary(Wardrik.t(), String.t(), String.t() | map()) :: :ok | {:error, term()}
  def put_boundary(wardrik, id, name) do
    with {:ok, _vsn} <- WardrikStore.put(store(wardrik), "boundaries/" <> id, name), do: :ok
  end

  @doc "Returns the name of the policy that bounds the agent `id`, or `nil`."
  @spec boundary(Wardrik.t(), String.t()) :: String.t() | map() | nil
  def boundary(wardrik, id), do: WardrikStore.get(store(wardrik), "boundaries/" <> id)

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
