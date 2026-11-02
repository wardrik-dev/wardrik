defmodule Wardrik.Test.Asked do
  @moduledoc "Tells the test each request, and decides as the test set it, in an `Agent`."
  @behaviour Wardrik.Authorizer

  @impl true
  def authorize(%Wardrik.Authorizer.Request{} = request, decider) do
    {test, decide} = Agent.get(decider, & &1)
    send(test, {:asked, request.principal.id, request.action, request.resource, request.context})
    decide.(request.action, request.resource)
  end
end

defmodule Wardrik.AuthorizerTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias Wardrik.Error

  @model "anthropic:claude-haiku-4-5"

  setup context do
    test = self()
    decider = start_supervised!({Agent, fn -> {test, fn _action, _resource -> :ok end} end})

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        authorizer: {Wardrik.Test.Asked, decider},
        deployment: "eu-1"
      )

    start_supervised!({Wardrik, wardrik})
    %{wardrik: wardrik, decider: decider, scope: Wardrik.as(wardrik, maria())}
  end

  defp decide(decider, decide), do: Agent.update(decider, fn {test, _old} -> {test, decide} end)

  defp define(scope, id),
    do: Wardrik.run(scope, "agent.define", %{"agent" => id, "model" => @model})

  test "asks about an agent by the ID it was given, for the principal acting", %{scope: scope} do
    assert {:ok, _agent} = define(scope, "acme/@maria/scout")
    assert_received {:asked, "acme/@maria", "agent.define", {:agent, "acme/@maria/scout"}, %{}}
  end

  test "says nothing of an agent the principal can't reach", %{scope: scope, decider: decider} do
    decide(decider, fn _action, _resource -> {:error, :not_found} end)

    assert define(scope, "acme/scout") ==
             {:error, Error.new(:not_found, "There's no agent acme/scout.")}

    decide(decider, fn _action, _resource -> {:error, :forbidden} end)

    assert define(scope, "acme/scout") ==
             {:error, Error.new(:forbidden, "You may not do this to the agent acme/scout.")}
  end

  test "lists only the agents it allows, asking about each", %{scope: scope, decider: decider} do
    for id <- ["acme/scout", "globex/scout"], do: {:ok, _agent} = define(scope, id)

    decide(decider, fn
      "agent.read", {:agent, "globex/scout"} -> {:error, :not_found}
      _action, _resource -> :ok
    end)

    assert {:ok, %{"agents" => agents}} = Wardrik.run(scope, "agents.list", %{})
    assert Enum.map(agents, & &1["id"]) == ["acme/scout"]
    assert_received {:asked, _maria, "agent.read", {:agent, "globex/scout"}, %{}}
  end

  test "names the deployment by its name, and an owner's items by owner and name", %{
    scope: scope
  } do
    assert {:ok, _nodes} = Wardrik.run(scope, "deployment.nodes", %{})
    assert_received {:asked, _maria, _action, {:deployment, "eu-1"}, %{}}

    assert {:ok, _servers} = Wardrik.run(scope, "mcp_servers.list", %{"owner" => "acme"})
    assert_received {:asked, _maria, "mcp_server.read", {:owner, "acme"}, %{name: nil}}
  end

  test "makes no token without an authorizer that says what a scope holds", %{scope: scope} do
    assert {:error, %Error{type: :forbidden}} =
             Wardrik.run(scope, "tokens.create", %{
               "name" => "ci",
               "resources" => ["*"],
               "roles" => ["owner"]
             })
  end
end
