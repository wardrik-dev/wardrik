defmodule WardrikProtocol.Inline do
  @moduledoc false

  @prefix "urn:wardrik:schema:v1:"

  @spec schema(Path.t(), String.t()) :: map()
  def schema(dir, name), do: whole(read(dir, name), dir)

  @spec read(Path.t(), String.t()) :: map()
  def read(dir, name) do
    dir
    |> Path.join(name <> ".json")
    |> File.read!()
    |> JSON.decode!()
    |> Map.drop(["$schema", "$id"])
  end

  @spec whole(term(), Path.t()) :: term()
  def whole(%{"$ref" => @prefix <> ref}, dir), do: whole(referenced(ref, dir), dir)

  def whole(%{} = schema, dir),
    do: Map.new(schema, fn {key, value} -> {key, whole(value, dir)} end)

  def whole(list, dir) when is_list(list), do: Enum.map(list, &whole(&1, dir))
  def whole(value, _dir), do: value

  defp referenced(ref, dir) do
    case String.split(ref, "#/$defs/") do
      [name, type] -> get_in(read(dir, name), ["$defs", type])
      [name] -> read(dir, name)
    end
  end
end
