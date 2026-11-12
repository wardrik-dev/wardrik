defmodule Wardrik.Definitions do
  @moduledoc false

  @prefix "definitions/"

  @doc "Stores `definition` for the agent `id`."
  @spec put(Wardrik.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(wardrik, id, definition) do
    with {:ok, _vsn} <- Wardrik.Store.put(store(wardrik), @prefix <> id, definition), do: :ok
  end

  @doc "Returns the agent `id`'s definition, or `:error` if it has none."
  @spec fetch(Wardrik.t(), String.t()) :: {:ok, map()} | :error
  def fetch(wardrik, id) do
    case Wardrik.Store.get(store(wardrik), @prefix <> id) do
      nil -> :error
      definition -> {:ok, definition}
    end
  end

  @doc "Removes the agent `id`'s definition and boundary."
  @spec delete(Wardrik.t(), String.t()) :: :ok | {:error, term()}
  def delete(wardrik, id) do
    with :ok <- Wardrik.Store.delete(store(wardrik), @prefix <> id),
         do: Wardrik.Store.delete(store(wardrik), "boundaries/" <> id)
  end

  @doc "Stores the policy of the scope that defined the agent `id`."
  @spec put_boundary(Wardrik.t(), String.t(), String.t() | map()) :: :ok | {:error, term()}
  def put_boundary(wardrik, id, name) do
    with {:ok, _vsn} <- Wardrik.Store.put(store(wardrik), "boundaries/" <> id, name), do: :ok
  end

  @doc "Returns the name of the policy that bounds the agent `id`, or `nil`."
  @spec boundary(Wardrik.t(), String.t()) :: String.t() | map() | nil
  def boundary(wardrik, id), do: Wardrik.Store.get(store(wardrik), "boundaries/" <> id)

  @doc "Returns the IDs of the agents with a definition."
  @spec ids(Wardrik.t()) :: [String.t()]
  def ids(wardrik) do
    wardrik
    |> store()
    |> Wardrik.Store.keys(@prefix)
    |> Enum.map(&String.replace_prefix(&1, @prefix, ""))
  end

  defp store(%Wardrik{store: store}), do: Wardrik.Store.scope(store, "wardrik")
end
