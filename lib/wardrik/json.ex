defmodule Wardrik.JSON do
  @moduledoc "Turns view results into JSON-ready operation results."

  @doc """
  Returns `value` with every key and atom as a string. Leaves `true`, `false` and `nil` alone.

      Wardrik.JSON.json(%{status: :idle})
      #=> %{"status" => "idle"}
  """
  @spec json(term()) :: term()
  def json(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), json(value)} end)
  def json(list) when is_list(list), do: Enum.map(list, &json/1)
  def json(value) when is_boolean(value) or is_nil(value), do: value
  def json(value) when is_atom(value), do: Atom.to_string(value)
  def json(value), do: value
end
