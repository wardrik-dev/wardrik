defmodule WardrikProtocol.Inline do
  @moduledoc false

  @prefix "urn:wardrik:schema:v1:"

  @spec schema(Path.t(), String.t()) :: map()
  def schema(dir, name), do: dir |> read(name) |> whole(dir)

  @spec read(Path.t(), String.t()) :: map()
  def read(dir, name) do
    dir
    |> Path.join(name <> ".json")
    |> File.read!()
    |> JSON.decode!()
    |> Map.drop(["$schema", "$id"])
  end

  @spec whole(term(), Path.t()) :: term()
  def whole(%{"$ref" => @prefix <> ref}, dir), do: ref |> referenced(dir) |> whole(dir)

  def whole(%{} = schema, dir),
    do: Map.new(schema, fn {key, value} -> {key, whole(value, dir)} end)

  def whole(list, dir) when is_list(list), do: Enum.map(list, &whole(&1, dir))
  def whole(value, _dir), do: value

  defp referenced(ref, dir) do
    case String.split(ref, "#/$defs/") do
      [name, type] -> dir |> read(name) |> get_in(["$defs", type])
      [name] -> read(dir, name)
    end
  end
end
