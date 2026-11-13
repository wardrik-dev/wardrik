defmodule Wardrik.ServerTest do
  use ExUnit.Case, async: true

  alias Wardrik.Operations.Functions
  alias Wardrik.Operations.Types
  alias Wardrik.Scope

  @inputs %{
    "agent.define" => [model: "anthropic:claude-haiku-4-5"],
    "agent.ask" => "What's on fire?",
    "agent.decide" => [
      decisions: %{"c1" => :approve, "c2" => {:deny, "No."}, "c3" => {:approve, "Once."}}
    ]
  }

  setup do
    %{
      scope: Scope.new(Wardrik.Test.Server, wardrik: self(), principal: "acme/@maria")
    }
  end

  test "runs every operation through the scope's server, and answers in structs", %{scope: scope} do
    for %{id: id} = operation <- WardrikProtocol.operations() do
      assert Wardrik.Test.Server.answers?(operation), "The test server can't answer #{id}."
      prefix = Functions.prefix(operation)
      module = Functions.module(prefix)
      args = [scope | arguments(operation, Map.get(@inputs, id, []))]

      answer = apply(module, Functions.name(operation), args)

      assert answered?(answer), id
      assert_received {:ran, ^id, input}
      path = Functions.path(operation)
      assert Enum.all?(path, &(input[&1] == "x")), id
    end
  end

  defp arguments(operation, input) do
    case {Functions.named?(operation), Functions.path(operation), Types.fields(operation)} do
      {true, path, _fields} -> [Enum.map(path, &{String.to_atom(&1), "x"}) ++ input]
      {false, path, []} -> Enum.map(path, fn _parameter -> "x" end)
      {false, path, _fields} -> Enum.map(path, fn _parameter -> "x" end) ++ [input]
    end
  end

  test "streams through the scope's server as structs, each with its cursor", %{scope: scope} do
    assert {:ok, stream} = Wardrik.Agent.stream_events(scope, "acme/triage")

    assert [{%Wardrik.Event{type: "wardrik.run.started", agent: "acme/triage"}, "cursor-1"}] =
             Enum.to_list(stream)

    assert_received {:streamed, "agent.events", %{"agent" => "acme/triage"}}
  end

  test "replies with what the server follows, and says how the run ended", %{scope: scope} do
    assert {:ok, %Wardrik.Reply{text: "Re: hi"}} = Wardrik.Agent.reply(scope, "acme/triage", "hi")

    assert {:waiting, [%Wardrik.Interrupt{id: "c1"} = interrupt]} =
             Wardrik.Agent.reply(scope, "acme/waiting", "hi")

    Wardrik.Agent.approve(scope, interrupt: interrupt)
    assert_received {:ran, "agent.approve", %{"agent" => "acme/waiting", "interrupt" => "c1"}}

    Wardrik.Agent.deny(scope, interrupt: %{interrupt | conversation: "C1"}, reason: "No.")

    assert_received {:ran, "agent.deny",
                     %{"agent" => "acme/waiting", "conversation" => "C1", "reason" => "No."}}

    assert {:error, %Wardrik.Error{type: :unavailable, message: "The run failed: It broke."}} =
             Wardrik.Agent.reply(scope, "acme/broken", "hi")

    stream = Wardrik.Agent.stream(scope, "acme/triage", "hi")
    assert Enum.join(stream) == "Re: hi"

    assert {:ok, %Wardrik.Reply{text: "In C1: hi"}} =
             Wardrik.Agent.reply(scope, "acme/triage", "hi", conversation: "C1")

    {:ok, ref} = Wardrik.Agent.stream(scope, "acme/triage", "hi", to: self())
    assert_receive {Wardrik, ^ref, {:done, %Wardrik.Reply{}}}
  end

  test "makes a scope for a principal acting directly, or through an actor" do
    scope = Scope.new(Wardrik.Test.Server, wardrik: :here, principal: "acme/@jon")

    assert %Scope{principal: %WardrikCore.Principal{id: "acme/@jon"}, actor: nil, context: %{}} =
             scope

    assert %Scope{actor: {:agent, "acme/@jon/notes"}, context: %{asked_by: "acme/@jon"}} =
             Scope.new(Wardrik.Test.Server,
               wardrik: :here,
               principal: "acme/@jon",
               actor: {:agent, "acme/@jon/notes"},
               context: %{asked_by: "acme/@jon"}
             )

    assert_raise ArgumentError, fn ->
      Scope.new(Wardrik.Test.Server, wardrik: :here, principal: "acme", grants: [])
    end
  end

  defp answered?(:ok), do: true
  defp answered?({:ok, _answer}), do: true
  defp answered?({:ok, _answer, _more}), do: true
  defp answered?(_other), do: false
end
