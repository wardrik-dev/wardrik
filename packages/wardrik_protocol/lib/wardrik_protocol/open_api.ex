defmodule WardrikProtocol.OpenAPI do
  @moduledoc """
  `openapi.json` bundled: one document a client generator reads whole, with
  no file of its own to find.

  `openapi.json` names the protocol's schemas as `v1/<file>`, and they name
  each other by `$id`, which a generator that reads files cannot follow. The
  bundle holds each schema it reaches as a component, by its file's name
  camelized, `agent_snapshot.json` as `AgentSnapshot`, with each `$ref` to it
  pointing there. `mix wardrik_protocol.bundle` writes it to
  `priv/openapi.bundled.json`.
  """

  @prefix "urn:wardrik:schema:v1:"

  @doc """
  `openapi.json` of `priv`, with every schema it reaches among its
  components. Raises where a schema's name is one of its own components'.
  """
  @spec bundle(Path.t()) :: map()
  def bundle(priv \\ Application.app_dir(:wardrik_protocol, "priv")) do
    {document, files} = priv |> Path.join("openapi.json") |> read() |> rewrite(nil, MapSet.new())
    own = document["components"]["schemas"]
    schemas = include(MapSet.to_list(files), Path.join(priv, "v1"), %{})

    case Enum.filter(Map.keys(schemas), &Map.has_key?(own, &1)) do
      [] -> put_in(document, ["components", "schemas"], Map.merge(own, schemas))
      names -> raise ArgumentError, "openapi.json names components #{inspect(names)} already"
    end
  end

  @doc "The component a schema of the protocol is, by its file's name: `AgentSnapshot`."
  @spec name(String.t()) :: String.t()
  def name(file), do: file |> String.replace(".", "_") |> Macro.camelize()

  # Each schema `files` names, and those they name in turn, as components.
  defp include([], _dir, schemas), do: schemas

  defp include([file | rest], dir, schemas) do
    if Map.has_key?(schemas, name(file)) do
      include(rest, dir, schemas)
    else
      {schema, named} =
        dir
        |> Path.join(file <> ".json")
        |> read()
        |> Map.drop(["$id", "$schema"])
        |> rewrite(file, MapSet.new())

      include(rest ++ MapSet.to_list(named), dir, Map.put(schemas, name(file), schema))
    end
  end

  # `value` with each `$ref` to a schema of the protocol, by its file or its
  # `$id`, and each within `file` itself, pointing at its component; and the
  # files it names.
  defp rewrite(%{"$ref" => ref} = value, file, named) do
    {ref, named} = component(ref, file, named)
    {rest, named} = rewrite(Map.delete(value, "$ref"), file, named)
    {Map.put(rest, "$ref", ref), named}
  end

  defp rewrite(map, file, named) when is_map(map) do
    Enum.reduce(map, {%{}, named}, fn {key, value}, {map, named} ->
      {value, named} = rewrite(value, file, named)
      {Map.put(map, key, value), named}
    end)
  end

  defp rewrite(list, file, named) when is_list(list) do
    {list, named} = Enum.map_reduce(list, named, &rewrite(&1, file, &2))
    {list, named}
  end

  defp rewrite(value, _file, named), do: {value, named}

  defp component("v1/" <> ref, _file, named) do
    [file | pointer] = String.split(ref, "#", parts: 2)
    named(Path.rootname(file), List.first(pointer, ""), named)
  end

  defp component(@prefix <> ref, _file, named) do
    [file | pointer] = String.split(ref, "#", parts: 2)
    named(file, List.first(pointer, ""), named)
  end

  defp component("#" <> pointer, file, named) when is_binary(file),
    do: named(file, pointer, named)

  defp component(ref, _file, named), do: {ref, named}

  defp named(file, pointer, named),
    do: {"#/components/schemas/" <> name(file) <> pointer, MapSet.put(named, file)}

  defp read(path), do: path |> File.read!() |> JSON.decode!()
end
