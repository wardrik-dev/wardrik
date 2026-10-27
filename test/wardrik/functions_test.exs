defmodule Wardrik.FunctionsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Operations.Functions
  alias Wardrik.Operations.Types

  test "does every operation with a function taking its path parameters" do
    for operation <- WardrikProtocol.operations() do
      module = Functions.module(Functions.prefix(operation))
      arity = 2 + length(Functions.path(operation))

      assert Code.ensure_loaded?(module), "There's no #{inspect(module)}."
      assert function_exported?(module, Functions.name(operation), arity), operation.id
      assert function_exported?(module, Functions.name(operation), arity - 1), operation.id
    end
  end

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
    types = [
      Wardrik.Agent,
      Wardrik.Activity,
      Wardrik.Interrupt,
      Wardrik.Message,
      Wardrik.Decision,
      Wardrik.Authorization,
      Wardrik.Call,
      Wardrik.Event,
      Wardrik.Page,
      Wardrik.Timeline,
      Wardrik.Run,
      Wardrik.Runs,
      Wardrik.Runs.Totals,
      Wardrik.Forgotten,
      Wardrik.Definition,
      Wardrik.Trigger,
      Wardrik.Trigger.Webhook,
      Wardrik.Connection,
      Wardrik.Connecting,
      Wardrik.MCPServer,
      Wardrik.MCPServerAdded,
      Wardrik.Token,
      Wardrik.TokenIssued,
      Wardrik.Nodes,
      Wardrik.Node,
      Wardrik.Spend,
      Wardrik.Amount
    ]

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

  describe "running" do
    setup :set_mimic_global
    setup :start_wardrik

    setup %{wardrik: wardrik} do
      stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
      stub(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, answer("Nothing.")} end)
      :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
      start_agent(wardrik, "acme/triage")
      %{scope: owner(wardrik)}
    end

    test "runs the operation, and answers in structs", %{scope: scope} do
      assert {:ok, cursor} = Wardrik.Events.head(scope)

      assert {:ok, %Wardrik.Message{id: "msg_1", cursor: _cursor}} =
               Wardrik.Agent.ask(scope, "acme/triage", content: "Hi", id: "msg_1")

      until("wardrik.run.completed")

      assert {:ok,
              %Wardrik.Agent{id: "acme/triage", status: :idle, activity: %Wardrik.Activity{}}} =
               Wardrik.Agent.read(scope, "acme/triage")

      assert {:ok, [%Wardrik.Agent{id: "acme/triage", status: :idle}]} =
               Wardrik.Agents.list(scope)

      assert {:ok, []} = Wardrik.Interrupts.list(scope)
      assert {:ok, %Wardrik.Page{events: [], next: 0}} = Wardrik.Audit.list(scope, limit: 1)

      assert {:ok, %Wardrik.Timeline{items: [%{"kind" => "user"}, %{"kind" => "run"}]}} =
               Wardrik.Agent.timeline(scope, "acme/triage")

      assert {:ok, %Wardrik.Runs{runs: [%Wardrik.Run{status: :completed}]}} =
               Wardrik.Agent.runs(scope, "acme/triage")

      assert {:ok, stream} =
               Wardrik.Events.stream_list(scope, after: cursor, types: ["wardrik.run.completed"])

      assert [{%Wardrik.Event{type: "wardrik.run.completed", time: %DateTime{}}, _cursor}] =
               Enum.take(stream, 1)

      assert :ok = Wardrik.Agent.cancel(scope, "acme/triage")
      assert {:ok, %Wardrik.Message{}} = Wardrik.Agent.ask(scope, "acme/triage", "Hi again")
    end

    test "takes path parameters over the same ones in input", %{scope: scope} do
      assert {:error, %Wardrik.Error{type: :not_found}} =
               Wardrik.Agent.read(scope, "acme/missing", agent: "acme/triage")
    end
  end
end
