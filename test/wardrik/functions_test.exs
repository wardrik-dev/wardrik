defmodule Wardrik.FunctionsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Operations.Functions

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

      assert module.__info__(:functions) == Functions.module(prefix).__info__(:functions)
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

    test "runs the operation with its path parameters", %{scope: scope} do
      assert {:ok, %{"cursor" => cursor}} = Wardrik.Events.head(scope)

      assert {:ok, %{"message" => %{"id" => "msg_1"}}} =
               Wardrik.Agent.ask(scope, "acme/triage", %{"id" => "msg_1", "content" => "Hi"})

      until("wardrik.run.completed")

      assert {:ok, %{"agent" => %{"id" => "acme/triage"}, "status" => "idle"}} =
               Wardrik.Agent.read(scope, "acme/triage")

      assert {:ok, %{"agents" => [%{"id" => "acme/triage"}]}} = Wardrik.Agents.list(scope)
      assert {:ok, %{"interrupts" => []}} = Wardrik.Interrupts.list(scope)
      assert {:ok, %{"events" => _events}} = Wardrik.Audit.list(scope, %{"limit" => 1})

      assert {:ok, stream} =
               Wardrik.Events.stream_list(scope, %{
                 "after" => cursor,
                 "types" => ["wardrik.run.completed"]
               })

      assert [{%{"type" => "wardrik.run.completed"}, _cursor}] = Enum.take(stream, 1)
    end

    test "takes path parameters over the same ones in input", %{scope: scope} do
      assert {:error, %Wardrik.Error{type: :not_found}} =
               Wardrik.Agent.read(scope, "acme/missing", %{"agent" => "acme/triage"})
    end
  end
end
