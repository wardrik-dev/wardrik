defmodule Tars.Event.SchemaTest do
  @moduledoc """
  Elasticsearch fixes a field's type per index, so a path in a CloudEvent's
  data must have one type across every event type, and a path that holds any
  JSON value must be one the index stores as `flattened`.
  """

  use ExUnit.Case, async: true

  @schemas Application.app_dir(:tars, "priv/protocol/v1")

  @flattened ~w(
    message.parts.arguments message.parts.response
    messages.parts.arguments messages.parts.response
    tool.call.arguments tool.call.result
  )

  defp read(file), do: file |> File.read!() |> JSON.decode!()

  defp paths do
    defs = read(Path.join(@schemas, "defs.json"))["$defs"]

    for file <- Path.wildcard(Path.join(@schemas, "*.json")),
        Path.basename(file, ".json") not in ["defs", "cloudevent"],
        reduce: %{} do
      acc -> walk(read(file), [], acc, defs)
    end
  end

  defp walk(%{"$ref" => "urn:tars:schema:v1:defs#/$defs/" <> name}, path, acc, defs),
    do: walk(Map.fetch!(defs, name), path, acc, defs)

  defp walk(%{"type" => "object"} = schema, path, acc, defs) do
    schema
    |> Map.get("properties", %{})
    |> Enum.reduce(note(acc, path, "object"), fn {key, value}, acc ->
      walk(value, path ++ [key], acc, defs)
    end)
  end

  # An array is indexed as the type of what it holds.
  defp walk(%{"type" => "array", "items" => items}, path, acc, defs),
    do: walk(items, path, acc, defs)

  defp walk(%{"type" => type}, path, acc, _defs), do: note(acc, path, type)
  defp walk(%{"const" => _value}, path, acc, _defs), do: note(acc, path, "string")
  defp walk(_any, path, acc, _defs), do: note(acc, path, "any")

  defp note(acc, [], _type), do: acc

  defp note(acc, path, type),
    do: Map.update(acc, Enum.join(path, "."), MapSet.new([type]), &MapSet.put(&1, type))

  test "every path in data has one type across every event type" do
    clashes = for {path, types} <- paths(), MapSet.size(types) > 1, do: {path, types}

    assert clashes == []
  end

  test "a path that holds any value is one the index stores as flattened" do
    any = for {path, types} <- paths(), MapSet.member?(types, "any"), do: path

    assert Enum.sort(any) == Enum.sort(@flattened)
  end
end
