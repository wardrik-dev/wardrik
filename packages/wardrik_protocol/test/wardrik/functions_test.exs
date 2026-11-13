defmodule Wardrik.FunctionsTest do
  use ExUnit.Case, async: true

  alias Wardrik.Operations.Functions
  alias Wardrik.Operations.Types

  test "does every operation with a function taking its path parameters" do
    for operation <- WardrikProtocol.operations(), not named?(operation) do
      module = Functions.module(Functions.prefix(operation))
      # An operation with input of its own takes it after its path parameters, optionally.
      input = if Types.fields(operation) == [], do: 0, else: 1
      arity = 1 + length(Functions.path(operation)) + input

      assert Code.ensure_loaded?(module), "There's no #{inspect(module)}."
      assert function_exported?(module, Functions.name(operation), arity), operation.id

      assert function_exported?(module, Functions.name(operation), arity - input),
             operation.id

      assert function_exported?(module, Functions.name(operation), arity + 1) ==
               (operation.conversation != nil),
             operation.id
    end
  end

  test "takes a conversation in opts, or in the input where it names its path parameters" do
    scope = %Wardrik.Scope{server: Wardrik.Test.Server, wardrik: self(), principal: nil}

    Wardrik.Agent.ask(scope, "agt_1", "Hi.", conversation: "C1")

    assert_received {:ran, "agent.ask",
                     %{"agent" => "agt_1", "content" => "Hi.", "conversation" => "C1"}}

    Wardrik.Agent.decide(scope,
      agent: "agt_1",
      decisions: %{"call_1" => :approve},
      conversation: "C1"
    )

    assert_received {:ran, "agent.decide", %{"conversation" => "C1", "decisions" => [_decision]}}

    Wardrik.Agent.ask(scope, "agt_1", "Hi.")
    assert_received {:ran, "agent.ask", input}
    refute Map.has_key?(input, "conversation")

    assert_raise ArgumentError, fn -> Wardrik.Agent.ask(scope, "agt_1", "Hi.", to: "C1") end

    Wardrik.Agent.deny(scope, agent: "agt_1", interrupt: "call_1", conversation: "C1")

    assert_received {:ran, "agent.deny",
                     %{"agent" => "agt_1", "interrupt" => "call_1", "conversation" => "C1"}}
  end

  test "refuses input it doesn't know" do
    scope = %Wardrik.Scope{server: Wardrik.Test.Server, wardrik: self(), principal: nil}

    for input <- [
          [content: "Hi.", conversation: "C1"],
          [content: "Hi.", colour: "red"],
          [content: "Hi.", agent: "agt_2"]
        ] do
      assert_raise ArgumentError, fn -> Wardrik.Agent.ask(scope, "agt_1", input) end
    end

    assert_raise ArgumentError, fn ->
      Wardrik.Agent.approve(scope, agent: "agt_1", interrupt: "call_1", colour: "red")
    end

    assert_raise ArgumentError, fn ->
      Wardrik.Agent.kill(scope, agent: "agt_1", call: "call_1", colour: "red")
    end

    assert_raise ArgumentError, fn -> Wardrik.Agents.list(scope, nope: true) end
    refute_received {:ran, _operation, _input}
  end

  test "names two or more path parameters in the input" do
    for operation <- WardrikProtocol.operations(), named?(operation) do
      name = Functions.module(Functions.prefix(operation))
      module = Code.ensure_loaded!(name)

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

    assert_raise ArgumentError, fn ->
      Types.named("agent.decide", [agent: "acme/books", decisions: %{}, colour: "red"], [:agent])
    end
  end

  defp named?(operation), do: Functions.named?(operation)

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
  defp wardriks?(value) when is_tuple(value), do: wardriks?(Tuple.to_list(value))
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
