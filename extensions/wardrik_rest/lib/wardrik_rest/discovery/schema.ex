defmodule WardrikRest.Discovery.Schema do
  @moduledoc """
  Turns Discovery schemas into JSON Schema, small enough to send with every model call.

  References are inlined, and a reference back to a schema already being inlined becomes a plain
  object. Only an argument keeps its description; fields the API only returns are left out.
  """

  @doc "Returns the JSON Schema of a method's parameter, with its description."
  @spec parameter(map()) :: map()
  def parameter(param) do
    one = Map.take(param, ["type", "enum", "pattern"])
    schema = if param["repeated"], do: %{"type" => "array", "items" => one}, else: one
    described(schema, param["description"])
  end

  @doc """
  Returns the fields of the request body `request` refers to, each with its JSON Schema and
  description, leaving out fields the API only returns.
  """
  @spec fields(map(), map()) :: [{String.t(), map()}]
  def fields(%{"$ref" => ref}, schemas) do
    for {name, field} <- Map.get(schemas[ref], "properties", %{}), field["readOnly"] != true do
      {name, described(json(field, schemas, [ref]), field["description"])}
    end
  end

  defp json(%{"$ref" => ref}, schemas, seen) do
    if ref in seen,
      do: %{"type" => "object"},
      else: json(Map.fetch!(schemas, ref), schemas, [ref | seen])
  end

  defp json(node, schemas, seen) do
    node
    |> Map.take(["type", "enum", "pattern"])
    |> Map.reject(fn {key, value} -> key == "type" and value == "any" end)
    |> put("properties", properties(node["properties"], schemas, seen))
    |> put("items", nested(node["items"], schemas, seen))
    |> put("additionalProperties", nested(node["additionalProperties"], schemas, seen))
  end

  defp properties(nil, _schemas, _seen), do: nil

  defp properties(properties, schemas, seen) do
    for {name, field} <- properties, field["readOnly"] != true, into: %{} do
      {name, json(field, schemas, seen)}
    end
  end

  defp nested(%{} = node, schemas, seen), do: json(node, schemas, seen)
  defp nested(_none, _schemas, _seen), do: nil

  defp put(schema, _key, nil), do: schema
  defp put(schema, key, value), do: Map.put(schema, key, value)

  defp described(schema, nil), do: schema
  defp described(schema, description), do: Map.put(schema, "description", description)
end
