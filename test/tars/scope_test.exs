defmodule Tars.ScopeTest do
  use ExUnit.Case, async: true

  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Test.EchoTool
  alias Tars.Trace

  defp tool!(name) do
    ReqLLM.Tool.new!(name: name, description: "test tool", callback: fn i -> {:ok, i} end)
  end

  test "root/3 pairs a config with a fresh root span" do
    config = Config.new()
    scope = Scope.root(config, :assistant, name: "turn")

    assert scope.config == config
    assert scope.source.agent_id == :assistant
    assert Trace.root?(scope.source.trace)
    assert scope.source.trace.name == "turn"
  end

  test "child/2 keeps the config and topic, and descends a span" do
    scope = Scope.root(Config.new(), :assistant)
    child = Scope.child(scope, name: "echo")

    assert child.config == scope.config
    assert child.source.agent_id == :assistant
    assert child.source.trace.parent_span_id == scope.source.trace.span_id
    assert child.source.trace.name == "echo"
  end

  test "child/3 swaps the config for delegated work" do
    scope = Scope.root(Config.new(), :assistant)
    researcher = Config.new(model_spec: {:test, model: "m"}, tools: [tool!("search")])

    child = Scope.child(scope, researcher, name: "researcher")

    assert child.config == researcher
    assert child.source.agent_id == :assistant
    assert child.source.trace.trace_id == scope.source.trace.trace_id
    assert child.source.trace.parent_span_id == scope.source.trace.span_id
  end

  test "child/2 carries the config, tools and all" do
    scope = Scope.root(Config.new(tools: [EchoTool]), :assistant)

    assert Scope.child(scope, name: "echo").config == scope.config
  end

  test "a scope's own children are siblings" do
    scope = Scope.root(Config.new(), :assistant)

    one = Scope.child(scope, name: "one")
    two = Scope.child(scope, name: "two")

    assert one.source.trace.parent_span_id == two.source.trace.parent_span_id
    assert one.source.trace.span_id != two.source.trace.span_id
  end
end
