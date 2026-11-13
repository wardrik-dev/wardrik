defmodule WardrikRest.OpenAPI.Schema do
  @moduledoc """
  Turns OpenAPI 3.0 and 3.1 schemas into JSON Schema for `WardrikRest.Spec`.

    * A reference to `#/components/schemas/NAME` stays a reference, as `%{"$ref" => "NAME"}`.
      Other references within the document are followed; references to other files are left as
      any value.
    * Fields the API only returns (`readOnly`) are left out, with them in `required`.
    * Kept: `type`, `enum`, `const`, `pattern`, `description`, `properties`, `required`, `items`,
      `additionalProperties`, `oneOf`, `anyOf` and `allOf`. `nullable` and a `"null"` type are
      dropped, as a tool's arguments may leave a field out.
  """

  @kept ["type", "enum", "const", "pattern", "description", "required"]
  @choices ["oneOf", "anyOf", "allOf"]
  @prefix "#/components/schemas/"

  @doc "Returns the document's `components/schemas` as types, by name."
  @spec types(map()) :: %{String.t() => map()}
  def types(document) do
    for {name, schema} <- get_in(document, ["components", "schemas"]) || %{}, into: %{} do
      {name, json(schema, document, [])}
    end
  end

  @doc "Returns `schema`, from `document`, as JSON Schema."
  @spec json(map() | boolean(), map()) :: map()
  def json(schema, document), do: json(schema, document, [])

  @doc """
  Follows `node`'s reference within `document`, to a parameter, a request body or any other
  object. Returns `node` itself when it isn't a reference, and `%{}` when it can't be followed.
  """
  @spec resolve(map(), map()) :: map()
  def resolve(node, document), do: resolve(node, document, [])

  defp resolve(%{"$ref" => "#/" <> pointer = ref}, document, seen) do
    if ref in seen do
      %{}
    else
      keys =
        pointer
        |> String.split("/")
        |> Enum.map(&unescape/1)

      document
      |> get_in(keys)
      |> found(document, [ref | seen])
    end
  end

  defp resolve(%{"$ref" => _elsewhere}, _document, _seen), do: %{}
  defp resolve(node, _document, _seen), do: node

  defp found(%{} = node, document, seen), do: resolve(node, document, seen)
  defp found(_none, _document, _seen), do: %{}

  defp unescape(part) do
    part
    |> String.replace("~1", "/")
    |> String.replace("~0", "~")
  end

  defp json(%{"$ref" => @prefix <> name} = node, _document, _seen) do
    case node["description"] do
      nil -> %{"$ref" => unescape(name)}
      description -> %{"$ref" => unescape(name), "description" => description}
    end
  end

  defp json(%{"$ref" => ref} = node, document, seen) do
    if ref in seen,
      do: %{},
      else: json(resolve(node, document), document, [ref | seen])
  end

  defp json(%{} = node, document, seen) do
    node
    |> Map.take(@kept)
    |> typed()
    |> Map.merge(
      Map.reject(
        %{
          "properties" => properties(node["properties"], document, seen),
          "items" => nested(node["items"], document, seen),
          "additionalProperties" => additional(node["additionalProperties"], document, seen)
        },
        fn {_key, value} -> is_nil(value) end
      )
    )
    |> choices(node, document, seen)
    |> required(node)
  end

  defp json(_any, _document, _seen), do: %{}

  defp typed(%{"type" => types} = schema) when is_list(types) do
    case types -- ["null"] do
      [type] -> %{schema | "type" => type}
      [] -> Map.delete(schema, "type")
      many -> %{schema | "type" => many}
    end
  end

  defp typed(schema), do: schema

  defp properties(%{} = properties, document, seen) do
    for {name, field} <- properties, not read_only?(field, document), into: %{} do
      {name, json(field, document, seen)}
    end
  end

  defp properties(_none, _document, _seen), do: nil

  defp read_only?(field, document), do: resolve(field, document)["readOnly"] == true

  defp nested(%{} = node, document, seen),
    do: Map.delete(json(node, document, seen), "description")

  defp nested(_none, _document, _seen), do: nil

  defp additional(%{} = node, document, seen), do: nested(node, document, seen)
  defp additional(false, _document, _seen), do: false
  defp additional(_any, _document, _seen), do: nil

  defp choices(schema, node, document, seen) do
    Enum.reduce(@choices, schema, fn key, schema ->
      case node[key] do
        [_ | _] = choices -> Map.put(schema, key, Enum.map(choices, &nested(&1, document, seen)))
        _none -> schema
      end
    end)
  end

  defp required(%{"required" => required, "properties" => properties} = schema, _node)
       when is_list(required) do
    case Enum.filter(required, &Map.has_key?(properties, &1)) do
      [] -> Map.delete(schema, "required")
      kept -> %{schema | "required" => kept}
    end
  end

  defp required(schema, _node), do: Map.delete(schema, "required")
end
