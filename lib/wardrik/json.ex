defmodule Wardrik.JSON do
  @moduledoc "Turns what a view returns into what an operation answers: string keys, and atoms as strings."

  @doc "Returns `value` with its keys and atoms as strings."
  @spec json(term()) :: term()
  def json(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), json(value)} end)
  def json(list) when is_list(list), do: Enum.map(list, &json/1)
  def json(value) when is_boolean(value) or is_nil(value), do: value
  def json(value) when is_atom(value), do: Atom.to_string(value)
  def json(value), do: value
end
