defmodule Tars.Scope.ContextTest do
  use ExUnit.Case, async: true

  alias Tars.LLM.Config
  alias Tars.Scope

  defp scope, do: Scope.root(Config.new(), :assistant)
  defp call, do: %{id: "call_1", name: "echo", arguments: %{"a" => 1}}

  test "there is nothing to read outside a tool call" do
    assert Scope.Context.current() == nil
    assert Scope.Context.current_call() == nil
    assert Scope.Context.current_call_id() == nil
  end

  test "put/2 records the scope and the call the process is answering" do
    :ok = Scope.Context.put(scope(), call())

    assert Scope.Context.current().source.agent_id == :assistant
    assert Scope.Context.current_call() == call()
    assert Scope.Context.current_call_id() == "call_1"
  end

  test "a scope can be recorded without a call, for work that is not one" do
    :ok = Scope.Context.put(scope())

    assert Scope.Context.current()
    assert Scope.Context.current_call() == nil
    assert Scope.Context.current_call_id() == nil
  end

  test "one process cannot see another's call" do
    :ok = Scope.Context.put(scope(), call())

    assert Task.await(Task.async(fn -> Scope.Context.current_call() end)) == nil
    assert Scope.Context.current_call_id() == "call_1"
  end
end
