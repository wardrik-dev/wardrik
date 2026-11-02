defmodule Wardrik.FunctionsTest do
  use ExUnit.Case, async: true

  alias Wardrik.Operations.Functions
  alias Wardrik.Operations.Types

  test "does every operation with a function taking its path parameters" do
    for operation <- WardrikProtocol.operations(), not named?(operation) do
      module = Functions.module(Functions.prefix(operation))
      arity = 2 + length(Functions.path(operation))

      assert Code.ensure_loaded?(module), "There's no #{inspect(module)}."
      assert function_exported?(module, Functions.name(operation), arity), operation.id
      assert function_exported?(module, Functions.name(operation), arity - 1), operation.id
    end
  end

  test "names two or more path parameters in the input" do
    for operation <- WardrikProtocol.operations(), named?(operation) do
      module = Code.ensure_loaded!(Functions.module(Functions.prefix(operation)))

      assert function_exported?(module, Functions.name(operation), 2), operation.id
      refute function_exported?(module, Functions.name(operation), 3), operation.id
    end

    assert Types.named("agent.deny", [agent: "acme/books", interrupt: "call_1", reason: "No."], [
             :agent,
             :interrupt
           ]) == %{"agent" => "acme/books", "interrupt" => "call_1", "reason" => "No."}

    assert_raise KeyError, fn ->
      Types.named("agent.kill", [agent: "acme/books"], [:agent, :call])
    end
  end

  defp named?(operation), do: match?([_first, _second | _more], Functions.path(operation))

  test "streams every operation that can be streamed, and nothing else" do
    for operation <- WardrikProtocol.operations() do
      module = Functions.module(Functions.prefix(operation))
      arity = 2 + length(Functions.path(operation))
      name = :"stream_#{Functions.name(operation)}"
      Code.ensure_loaded!(module)

      assert function_exported?(module, name, arity) == operation.stream, operation.id
    end
  end

  test "defines the same functions again from the protocol" do
    for prefix <- Enum.uniq(Enum.map(WardrikProtocol.operations(), &Functions.prefix/1)) do
      module = Module.concat(__MODULE__, Macro.camelize(prefix))
      using = quote(do: use(Wardrik.Operations.Functions, prefix: unquote(prefix)))

      Module.create(module, using, Macro.Env.location(__ENV__))

      generated = MapSet.new(module.__info__(:functions))
      assert MapSet.subset?(generated, MapSet.new(Functions.module(prefix).__info__(:functions)))
      assert MapSet.size(generated) > 0
    end
  end

  test "decodes every answer the protocol gives an example of" do
    for %{id: id, output: %{"examples" => examples}} <- WardrikProtocol.operations(),
        example <- examples do
      decoded = Types.decode(id, example)
      assert elem(decoded, 0) == :ok, id
      assert wardriks?(decoded), "#{id} answers a struct from outside Wardrik.*"
    end
  end

  test "reads every property of the schema each type is of" do
    {:ok, modules} = :application.get_key(:wardrik_protocol, :modules)
    types = Enum.filter(modules, &function_exported?(Code.ensure_loaded!(&1), :__schema__, 0))
    assert Wardrik.Authorization in types

    for type <- types do
      [name | path] = type.__schema__()
      schema = Enum.reduce(path, WardrikProtocol.schema(name), &Map.fetch!(&2, &1))
      properties = Map.fetch!(schema, "properties")

      read =
        for {_field, spec} <- type.__fields__(),
            path = Wardrik.Type.path(spec),
            into: MapSet.new(),
            do: hd(path)

      assert read == MapSet.new(Map.keys(properties)), inspect(type)
    end
  end

  defp wardriks?(%DateTime{}), do: true
  defp wardriks?(%Date{}), do: true

  defp wardriks?(%module{} = value),
    do:
      String.starts_with?(Atom.to_string(module), "Elixir.Wardrik.") and
        wardriks?(Map.from_struct(value))

  defp wardriks?(value) when is_map(value),
    do: Enum.all?(value, fn {_key, item} -> wardriks?(item) end)

  defp wardriks?(value) when is_list(value), do: Enum.all?(value, &wardriks?/1)
  defp wardriks?(value) when is_tuple(value), do: value |> Tuple.to_list() |> wardriks?()
  defp wardriks?(_value), do: true

  test "writes each type back as the protocol's JSON it was read from" do
    for %{id: id, output: %{"examples" => examples}} <- WardrikProtocol.operations(),
        id in ~w(agent.read agent.trigger_set),
        example <- examples do
      {:ok, decoded} = Types.decode(id, example)
      assert decoded.__struct__.to_json(decoded) == example, id
    end
  end
end
