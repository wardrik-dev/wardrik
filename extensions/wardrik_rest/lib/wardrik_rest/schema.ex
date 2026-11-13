defmodule WardrikRest.Schema do
  @moduledoc """
  Fits an operation's arguments into a size budget, as the JSON Schema of its tool.

  Objects are listed as deep as the budget allows, the same depth for every argument, whether
  they're the spec's types or written in place. An object past that depth is left as an object
  that names it: a type by its name, and one written in place by its path from the tool or the
  type it's in. One inside itself is `"A FilterExpression, as above."`.

      %{"type" => "object", "description" => "A Campaign; ads__describe gives its fields."}

      %{"type" => "object",
        "description" => ~s(An object; stripe__describe gives its fields as "stripe__PostCharges/shipping".)}

  Only arguments keep their descriptions; `describe/4` gives an object's.
  """

  alias WardrikRest.Parameter

  @choices ["oneOf", "anyOf", "allOf"]
  @brief 200

  @typedoc "JSON Schemas by name, which may refer to each other as `%{\"$ref\" => name}`."
  @type types() :: %{String.t() => map()}

  @doc """
  Returns the JSON Schema of each of `parameters`, by name, within `budget` bytes of JSON where it
  can be, and the names of the objects it left out. `tool` is the tool's name, which paths start
  from, and `describe` names the tool that describes them.
  """
  @spec fit([Parameter.t()], types(), pos_integer(), {String.t(), String.t()}) ::
          {%{String.t() => map()}, [String.t()]}
  def fit(parameters, types, budget, {tool, describe}) do
    how = %{types: types, describe: describe, tool: tool}
    fit(parameters, how, budget, 0, nil)
  end

  defp fit(parameters, how, budget, depth, fitted) do
    {schemas, cut} = inlined = at(parameters, how, depth)
    over = size(schemas) > budget

    cond do
      over and fitted != nil -> fitted
      over -> at(parameters, Map.put(how, :brief, true), depth)
      cut == [] -> inlined
      true -> fit(parameters, how, budget, depth + 1, inlined)
    end
  end

  # When even every object left out is too long, each argument keeps its description's first
  # sentence.
  defp brief(nil, _how), do: nil

  defp brief(description, %{brief: true}) do
    description
    |> String.split(~r/(?<=[.!?])\s/, parts: 2)
    |> hd()
    |> String.slice(0, @brief)
  end

  defp brief(description, _how), do: description

  defp at(parameters, how, depth) do
    {schemas, cut} =
      Enum.map_reduce(parameters, [], fn %Parameter{name: name, schema: schema}, cut ->
        {inlined, more} = inline(schema, how, depth, {[], "#{how.tool}/#{name}"})
        {{name, described(inlined, brief(schema["description"], how))}, [more | cut]}
      end)

    cut =
      cut
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    {Map.new(schemas), cut}
  end

  defp size(schemas), do: byte_size(JSON.encode!(schemas))

  @doc """
  Returns the object `name` names, with its fields' descriptions, and the objects inside it as
  named objects. `name` is a type of `types`, or a path from one or from a tool of `tools`, the
  JSON Schema of each tool's arguments by its name. `describe` names the tool that describes them.
  """
  @spec describe(types(), %{String.t() => map()}, String.t(), String.t()) :: {:ok, map()} | :error
  def describe(types, tools, name, describe) do
    [root | path] = String.split(name, "/")
    how = %{types: types, describe: describe, tool: nil}

    with {:ok, start} <- root(types, tools, root),
         {:ok, object} <- walk(start, path, types) do
      seen = if Map.has_key?(types, root) and path == [], do: [root], else: []
      {:ok, fields(object, how, seen, name)}
    end
  end

  defp root(types, tools, root) do
    case {Map.fetch(types, root), Map.fetch(tools, root)} do
      {{:ok, type}, _tool} -> {:ok, type}
      {:error, {:ok, tool}} -> {:ok, tool}
      {:error, :error} -> :error
    end
  end

  defp walk(node, [], types), do: {:ok, object(node, types, [])}

  defp walk(node, [field | path], types) do
    case object(node, types, []) do
      %{"properties" => %{^field => next}} -> walk(next, path, types)
      _none -> :error
    end
  end

  # Down through references, lists and maps to the object they hold.
  defp object(%{"$ref" => ref}, types, seen) do
    if ref in seen, do: %{}, else: object(Map.get(types, ref, %{}), types, [ref | seen])
  end

  defp object(%{"properties" => _properties} = object, _types, _seen), do: object
  defp object(%{"items" => %{} = items}, types, seen), do: object(items, types, seen)

  defp object(%{"additionalProperties" => %{} = values}, types, seen),
    do: object(values, types, seen)

  defp object(%{} = node, types, seen) do
    choices = Enum.flat_map(@choices, &List.wrap(node[&1]))

    objects = Enum.map(choices, &object(&1, types, seen))

    case Enum.find(objects, &Map.has_key?(&1, "properties")) do
      nil -> node
      object -> object
    end
  end

  defp object(other, _types, _seen), do: other

  defp fields(%{"properties" => properties} = object, how, seen, path)
       when map_size(properties) > 0 do
    fields =
      for {field, schema} <- properties, into: %{} do
        {inlined, _cut} = inline(schema, how, 0, {seen, "#{path}/#{field}"})
        {field, described(inlined, schema["description"])}
      end

    Map.put(object, "properties", fields)
  end

  defp fields(object, _how, _seen, _path), do: object

  defp inline(%{"$ref" => ref}, how, depth, {seen, _path}) do
    type = Map.get(how.types, ref, %{})

    cond do
      ref in seen -> {%{"type" => "object", "description" => "A #{ref}, as above."}, []}
      depth == 0 and object?(type) -> {named(ref, how.describe), [ref]}
      true -> inline(type, how, depth, {[ref | seen], ref})
    end
  end

  defp inline(%{"properties" => properties}, how, 0, {_seen, path})
       when map_size(properties) > 0,
       do: {placed(path, how.describe), [path]}

  # The objects cut come back as nested lists, flattened once by at/3.
  defp inline(schema, how, depth, {seen, path}) do
    schema
    |> Map.delete("description")
    |> each(fn
      {"properties", properties} ->
        each(properties, fn {name, field} ->
          inline(field, how, depth - 1, {seen, "#{path}/#{name}"})
        end)

      {key, %{} = nested} when key in ["items", "additionalProperties"] ->
        inline(nested, how, depth, {seen, path})

      {key, [_ | _] = choices} when key in @choices ->
        choices
        |> Enum.map(&inline(&1, how, depth, {seen, path}))
        |> Enum.unzip()

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

  defp object?(type),
    do: type["type"] == "object" or Enum.any?(["properties" | @choices], &Map.has_key?(type, &1))

  defp named(ref, describe),
    do: %{"type" => "object", "description" => "A #{ref}; #{describe} gives its fields."}

  defp placed(path, describe),
    do: %{
      "type" => "object",
      "description" => ~s(An object; #{describe} gives its fields as "#{path}".)
    }

  defp described(schema, nil), do: schema

  defp described(%{"description" => named} = schema, description),
    do: %{schema | "description" => "#{description} #{named}"}

  defp described(schema, description), do: Map.put(schema, "description", description)
end
