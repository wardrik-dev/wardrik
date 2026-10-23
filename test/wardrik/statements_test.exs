defmodule Wardrik.StatementsTest do
  use ExUnit.Case, async: true

  alias Wardrik.Authorizer
  alias Wardrik.Resource
  alias Wardrik.Statement

  @wardrik Wardrik.new(name: :statements, store: nil)

  defp authorize(statements, action, agent) do
    {:ok, resource} = Resource.agent(agent)
    scope = Wardrik.as(@wardrik, Wardrik.Test.Wardrik.maria(), statements)
    Authorizer.authorize(scope, action, resource)
  end

  test "allows what a statement's actions or roles name, on what its patterns cover" do
    statements = [
      Statement.new(roles: [:reader, :messenger], resources: ["acme/agent/*"]),
      Statement.new(roles: [:owner], resources: ["acme/@maria/*"])
    ]

    assert authorize(statements, "agent.ask", "acme/triage") == :ok
    assert authorize(statements, "agent.events", "acme/triage") == :ok
    assert authorize(statements, "agent.decide", "acme/@maria/books") == :ok
  end

  test "refuses an action it reaches the agent without, and hides an agent it doesn't reach" do
    statements = [Statement.new(actions: ["agent.read"], resources: ["acme/agent/*"])]

    assert authorize(statements, "agent.ask", "acme/triage") == {:error, :forbidden}
    assert authorize(statements, "agent.read", "acme/@jon/books") == {:error, :not_found}
    assert authorize(statements, "agent.read", "globex/triage") == {:error, :not_found}
    assert authorize([], "agent.read", "acme/triage") == {:error, :not_found}
  end

  test "takes a wildcard in actions" do
    statements = [Statement.new(actions: ["agent.*"], resources: ["*"])]

    assert authorize(statements, "agent.decide", "globex/triage") == :ok

    assert Authorizer.authorize(
             Wardrik.as(@wardrik, Wardrik.Test.Wardrik.maria(), statements),
             "deployment.audit",
             Resource.deployment()
           ) == {:error, :forbidden}
  end

  test "names an agent's resource by its ID" do
    assert Resource.agent("acme/triage") == {:ok, "acme/agent/triage"}
    assert Resource.agent("acme/@jon/triage") == {:ok, "acme/@jon/agent/triage"}

    for id <- ["acme", "acme/triage/extra", "acme/*", "acme/", "acme/@jon/", "a/b/c/d"],
        do: assert(Resource.agent(id) == :error)
  end
end
