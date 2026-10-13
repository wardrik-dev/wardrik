defmodule WardrikProtocol.Inline do
  @moduledoc false

  # Reads a schema of `dir` with each `$ref` to another of its schemas, or to
  # a type of `defs.json`, put in its place. `WardrikProtocol` calls it as it
  # compiles.

  @prefix "urn:wardrik:schema:v1:"

  @spec schema(Path.t(), String.t()) :: map()
  def schema(dir, name), do: dir |> read(name) |> Map.drop(["$schema", "$id"]) |> whole(dir)

  defp read(dir, name), do: dir |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()

  defp whole(%{"$ref" => @prefix <> "defs#/$defs/" <> type}, dir),
    do: dir |> read("defs") |> get_in(["$defs", type]) |> whole(dir)

  defp whole(%{"$ref" => @prefix <> name}, dir),
    do: dir |> read(name) |> Map.drop(["$schema", "$id", "examples"]) |> whole(dir)

  defp whole(%{} = schema, dir),
    do: Map.new(schema, fn {key, value} -> {key, whole(value, dir)} end)

  defp whole(list, dir) when is_list(list), do: Enum.map(list, &whole(&1, dir))
  defp whole(value, _dir), do: value
end
