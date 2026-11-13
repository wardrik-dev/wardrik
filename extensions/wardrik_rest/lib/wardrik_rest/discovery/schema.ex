defmodule WardrikRest.Discovery.Schema do
  @moduledoc """
  Turns Discovery schemas into JSON Schema types for `WardrikRest.Spec`.

  A reference to another schema stays a reference, as `%{"$ref" => "Campaign"}`, by the schema's
  short name: a prefix ending in `__`, as Google Ads' `GoogleAdsGoogleadsV24Resources__`, is
  dropped where the rest is still unique. Fields the API only returns are left out, and so are
  the `UNSPECIFIED` and `UNKNOWN` values Google gives its enums, which no request may send.
  """

  @placeholders ["UNSPECIFIED", "UNKNOWN"]

  @doc "Returns every schema of `schemas` as a JSON Schema type, by its short name."
  @spec types(map()) :: %{String.t() => map()}
  def types(schemas) do
    names = names(schemas)
    Map.new(schemas, fn {name, schema} -> {names[name], json(schema, names)} end)
  end

  @doc "Returns the short name of each schema of `schemas`, by its name in the document."
  @spec names(map()) :: %{String.t() => String.t()}
  def names(schemas) do
    all = Map.keys(schemas)
    prefixes = for name <- all, [prefix, _rest] <- [split(name)], uniq: true, do: prefix
    short = Map.new(all, &{&1, short(&1, prefixes)})

    taken =
      short
      |> Map.values()
      |> Enum.frequencies()

    Map.new(short, fn {name, short} -> {name, if(taken[short] == 1, do: short, else: name)} end)
  end

  defp split(name), do: String.split(name, "__", parts: 2)

  # Google Ads nests types with one underscore under the same prefix, as
  # `GoogleAdsGoogleadsV24Resources_Campaign_ShoppingSetting`.
  defp short(name, prefixes) do
    case split(name) do
      [_prefix, rest] -> rest
      [name] -> Enum.find_value(prefixes, name, &trimmed(name, &1 <> "_"))
    end
  end

  defp trimmed(name, prefix) do
    if String.starts_with?(name, prefix), do: String.replace_prefix(name, prefix, "")
  end

  @doc "Returns the JSON Schema of a method's parameter, with its description."
  @spec parameter(map()) :: map()
  def parameter(param) do
    one =
      param
      |> Map.take(["type", "enum", "pattern"])
      |> enum()

    schema = if param["repeated"], do: %{"type" => "array", "items" => one}, else: one
    described(schema, param["description"])
  end

  @doc """
  Returns the fields of the request body `request` refers to, each with its JSON Schema, leaving
  out fields the API only returns. `names` are the schemas' short names.
  """
  @spec fields(map(), map(), map()) :: [{String.t(), map()}]
  def fields(%{"$ref" => ref}, schemas, names) do
    schemas
    |> Map.fetch!(ref)
    |> json(names)
    |> Map.get("properties", %{})
    |> Map.to_list()
  end

  defp json(%{"$ref" => ref} = node, names),
    do: described(%{"$ref" => Map.get(names, ref, ref)}, node["description"])

  defp json(node, names) do
    node
    |> Map.take(["type", "enum", "pattern", "description"])
    |> Map.reject(fn {key, value} -> key == "type" and value == "any" end)
    |> enum()
    |> put("properties", properties(node["properties"], names))
    |> put("items", nested(node["items"], names))
    |> put("additionalProperties", nested(node["additionalProperties"], names))
  end

  defp properties(nil, _names), do: nil

  defp properties(properties, names) do
    for {name, field} <- properties, field["readOnly"] != true, into: %{} do
      {name, json(field, names)}
    end
  end

  defp nested(%{} = node, names), do: Map.delete(json(node, names), "description")
  defp nested(_none, _names), do: nil

  defp enum(%{"enum" => values} = schema) do
    case values -- @placeholders do
      [] -> schema
      kept -> %{schema | "enum" => kept}
    end
  end

  defp enum(schema), do: schema

  defp put(schema, _key, nil), do: schema
  defp put(schema, key, value), do: Map.put(schema, key, value)

  defp described(schema, nil), do: schema
  defp described(schema, description), do: Map.put(schema, "description", description)
end
