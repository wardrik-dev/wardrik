defmodule Wardrik.Test.GivesAll do
  @moduledoc "A resolver that gives every agent what the test set."
  @behaviour Wardrik.Resolver

  @impl Wardrik.Resolver
  def resolve(_request, given), do: {:ok, struct!(Wardrik.Resolved, given)}
end

defmodule Wardrik.Test.Drops do
  @moduledoc "A notify target that drops each notice."
  @behaviour Wardrik.Notify

  @impl Wardrik.Notify
  def deliver(_notice, _opts), do: :ok
end

defmodule Wardrik.ResolvedTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"

  setup context do
    store_name = :"store #{context.test}"
    store = Wardrik.Test.Store.new(store_name)

    given = [
      principal: %WardrikCore.Principal{id: "user_42"},
      policy: [deny: ["shell/*"]],
      policies: %{"careful" => [ask: ["echo"]]},
      defaults: %{"model" => @model},
      servers: %{"github" => "down"},
      notify: %{"ops" => "ops", "pager" => {Wardrik.Test.Drops, []}},
      channels: %{"slack" => "T0123"},
      workspaces: %{"acme/runbooks" => :read}
    ]

    wardrik =
      Wardrik.new(
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.GivesAll, given},
        name: :"wardrik #{context.test}",
        store: store,
        deployment: "test",
        mcp: [{"down", [transport: {:stdio, command: "no-such-mcp-server"}]}]
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})
    %{scope: owner(wardrik)}
  end

  test "shows what the app gives an agent", %{scope: scope} do
    {:ok, _agent} = Wardrik.Agent.define(scope, "acme/bot", model: @model)

    assert run!(scope, "agent.resolved", %{"agent" => "acme/bot"}) == %{
             "agent" => "acme/bot",
             "principal" => %{"id" => "user_42"},
             "servers" => [
               %{"name" => "github", "server" => "down", "owner" => "deployment", "tools" => []}
             ],
             "policy" => [%{"deny" => ["shell/*"]}],
             "policies" => %{"careful" => %{"ask" => ["echo"]}},
             "defaults" => %{"model" => @model},
             "notify" => [%{"name" => "ops", "target" => "ops"}, %{"name" => "pager"}],
             "channels" => %{"slack" => "T0123"},
             "workspaces" => %{"acme/runbooks" => "read"}
           }

    assert {:ok, %Wardrik.AgentResolved{principal: %{"id" => "user_42"}}} =
             Wardrik.Agent.resolved(scope, "acme/bot")

    assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Agent.resolved(scope, "acme/none")
  end
end
