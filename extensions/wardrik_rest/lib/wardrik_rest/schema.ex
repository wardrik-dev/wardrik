defmodule WardrikRest.Schema do
  @moduledoc """
  Fits an operation's arguments into a size budget, as the JSON Schema of its tool.

  References to the spec's types are inlined as deep as the budget allows, the same depth for
  every argument. An object type past that depth is left as an object that names it, and one
  inside itself as `"A FilterExpression, as above."`:

      %{"type" => "object", "description" => "A Campaign; ads__describe gives its fields."}

  Only arguments keep their descriptions; `describe/3` gives a type's.
  """

  alias WardrikRest.Parameter

  @typedoc "JSON Schemas by name, which may refer to each other as `%{\"$ref\" => name}`."
  @type types() :: %{String.t() => map()}

  @doc """
  Returns the JSON Schema of each of `parameters`, by name, within `budget` bytes of JSON where it
  can be, and the types it left as named objects. `describe` names the tool that describes them.
  """
  @spec fit([Parameter.t()], types(), pos_integer(), String.t()) ::
          {%{String.t() => map()}, [String.t()]}
  def fit(parameters, types, budget, describe),
    do: fit(parameters, types, budget, describe, 0, nil)

  defp fit(parameters, types, budget, describe, depth, fitted) do
    {schemas, cut} = inlined = at(parameters, types, depth, describe)
    over = size(schemas) > budget

    cond do
      over and fitted != nil -> fitted
      over or cut == [] -> inlined
      true -> fit(parameters, types, budget, describe, depth + 1, inlined)
    end
  end

  defp at(parameters, types, depth, describe) do
    {schemas, cut} =
      Enum.map_reduce(parameters, [], fn %Parameter{name: name, schema: schema}, cut ->
        {inlined, more} = inline(schema, %{types: types, describe: describe}, depth, [])
        {{name, described(inlined, schema["description"])}, [more | cut]}
      end)

    {Map.new(schemas), cut |> List.flatten() |> Enum.uniq() |> Enum.sort()}
  end

  defp size(schemas), do: schemas |> JSON.encode!() |> byte_size()

  @doc """
  Returns the type `name` of `types`, with its fields' descriptions, and the types its fields
  refer to as named objects. `describe` names the tool that describes them.
  """
  @spec describe(types(), String.t(), String.t()) :: {:ok, map()} | :error
  def describe(types, name, describe) do
    with {:ok, type} <- Map.fetch(types, name) do
      fields =
        for {field, schema} <- Map.get(type, "properties", %{}), into: %{} do
          {inlined, _cut} = inline(schema, %{types: types, describe: describe}, 0, [name])
          {field, described(inlined, schema["description"])}
        end

      {:ok, if(fields == %{}, do: type, else: Map.put(type, "properties", fields))}
    end
  end

  defp inline(%{"$ref" => ref}, how, depth, seen) do
    type = Map.get(how.types, ref, %{})

    cond do
      ref in seen -> {%{"type" => "object", "description" => "A #{ref}, as above."}, []}
      depth == 0 and object?(type) -> {named(ref, how.describe), [ref]}
      true -> inline(type, how, max(depth - 1, 0), [ref | seen])
    end
  end

  # The types cut come back as nested lists, flattened once by at/4.
  defp inline(schema, how, depth, seen) do
    schema
    |> Map.delete("description")
    |> each(fn
      {"properties", properties} ->
        each(properties, fn {_name, field} -> inline(field, how, depth, seen) end)

      {key, %{} = nested} when key in ["items", "additionalProperties"] ->
        inline(nested, how, depth, seen)

      {_key, value} ->
        {value, []}
    end)
  end

  defp each(map, inline) do
    {pairs, cut} =
      Enum.map_reduce(map, [], fn {key, _value} = pair, cut ->
        {inlined, more} = inline.(pair)
        {{key, inlined}, [more | cut]}
      end)

    {Map.new(pairs), cut}
  end

  defp object?(type), do: type["type"] == "object" or Map.has_key?(type, "properties")

  defp named(ref, describe),
    do: %{"type" => "object", "description" => "A #{ref}; #{describe} gives its fields."}

  defp described(schema, nil), do: schema

  defp described(%{"description" => named} = schema, description),
    do: %{schema | "description" => "#{description} #{named}"}

  defp described(schema, description), do: Map.put(schema, "description", description)
end
