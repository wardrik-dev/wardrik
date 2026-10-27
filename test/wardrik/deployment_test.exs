defmodule Wardrik.DeploymentTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        deployment: "test",
        capabilities: [tools: Wardrik.Test.Tools],
        policies: [careful: [ask: ["echo"]]]
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  describe "tokens" do
    test "makes a token whose secret acts as whoever made it, until it's revoked", %{
      wardrik: wardrik,
      scope: scope
    } do
      assert {:ok,
              %Wardrik.TokenIssued{
                token: %Wardrik.Token{id: id, principal: "acme/@maria"} = token,
                secret: secret
              }} =
               Wardrik.Tokens.create(scope,
                 name: "ci",
                 roles: ["reader"],
                 resources: ["acme/agent/*"]
               )

      assert %Wardrik.Token{
               statements: [%Wardrik.Statement{resources: ["acme/agent/*"]}],
               expires: %DateTime{}
             } = token

      assert {:ok, [%Wardrik.Token{id: ^id}]} = Wardrik.Tokens.list(scope)

      assert {:ok, ci} = Wardrik.authenticate(wardrik, secret)
      assert %Wardrik.Scope{principal: %{id: "acme/@maria"}} = ci
      assert {:ok, []} = Wardrik.Agents.list(ci)
      assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Tokens.list(ci)

      assert {:ok, %Wardrik.Token{id: ^id}} = Wardrik.Tokens.revoke(scope, token)
      assert {:error, %Wardrik.Error{type: :unauthorized}} = Wardrik.authenticate(wardrik, secret)
      assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Tokens.revoke(scope, id)

      assert {:ok, changes} = Wardrik.Audit.list(scope)

      assert ["wardrik.token.created", "wardrik.token.revoked"] =
               Enum.map(changes.events, & &1.type)
    end

    test "turns away what isn't a token, or has expired", %{wardrik: wardrik, scope: scope} do
      {:ok, %Wardrik.TokenIssued{token: %Wardrik.Token{id: id}, secret: secret}} =
        Wardrik.Tokens.create(scope, name: "brief", roles: ["reader"], resources: ["*"])

      assert {:error, %Wardrik.Error{type: :unauthorized}} = Wardrik.authenticate(wardrik, "nope")

      assert {:error, %Wardrik.Error{type: :unauthorized}} =
               Wardrik.authenticate(wardrik, "wrk_000000000000_x")

      assert {:error, %Wardrik.Error{type: :unauthorized}} =
               Wardrik.authenticate(wardrik, secret <> "x")

      tokens = WardrikStore.scope(wardrik.store, "wardrik")
      past = DateTime.utc_now() |> DateTime.add(-1) |> DateTime.to_iso8601()
      kept = WardrikStore.get(tokens, "tokens/" <> id)
      {:ok, _vsn} = WardrikStore.put(tokens, "tokens/" <> id, %{kept | "expires" => past})
      assert {:error, %Wardrik.Error{type: :unauthorized}} = Wardrik.authenticate(wardrik, secret)

      assert {:error, %Wardrik.Error{type: :invalid_request}} =
               Wardrik.Tokens.create(scope, name: "odd", roles: ["boss"], resources: ["*"])

      assert {:error, %Wardrik.Error{type: :invalid_request}} =
               Wardrik.Tokens.create(scope,
                 name: "odd",
                 roles: ["reader"],
                 resources: ["*"],
                 policy: "lax"
               )
    end

    test "holds every agent a token defines to the policy it names", %{
      wardrik: wardrik,
      scope: scope
    } do
      stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
        {:ok, calling([call("call_1", "echo", %{})])}
      end)

      {:ok, %Wardrik.TokenIssued{secret: secret}} =
        Wardrik.Tokens.create(scope,
          name: "ci",
          roles: ["owner"],
          resources: ["*"],
          policy: "careful"
        )

      {:ok, ci} = Wardrik.authenticate(wardrik, secret)
      assert %Wardrik.Scope{policy: "careful"} = ci

      {:ok, _agent} = Wardrik.Agent.define(ci, "acme/bot", model: @model, tools: ["tools"])

      assert {:waiting, [%Wardrik.Interrupt{id: "call_1"}]} =
               Wardrik.Agent.reply(ci, "acme/bot", "Echo")
    end
  end

  describe "the deployment" do
    test "lists its nodes, moves an agent, and reads every definition again", %{scope: scope} do
      here = to_string(node())
      {:ok, _agent} = Wardrik.Agent.define(scope, "acme/bot", model: @model)

      assert {:ok, %Wardrik.Nodes{nodes: [%Wardrik.Node{name: ^here, agents: 1}], asleep: 0}} =
               Wardrik.Deployment.nodes(scope)

      assert {:ok, %Wardrik.Agent{id: "acme/bot", node: ^here}} =
               Wardrik.Agent.move(scope, "acme/bot", node: here)

      assert {:error, %Wardrik.Error{type: :invalid_request}} =
               Wardrik.Agent.move(scope, "acme/bot", node: "nowhere@nohost")

      assert {:error, %Wardrik.Error{type: :not_found}} =
               Wardrik.Agent.move(scope, "acme/none", node: here)

      assert {:ok, %Wardrik.Agent{node: ^here}} = Wardrik.Agent.read(scope, "acme/bot")
      assert {:ok, [^here]} = Wardrik.Deployment.reload(scope)

      {:ok, %Wardrik.Agent{node: nil}} = Wardrik.Agent.stop(scope, "acme/bot")
    end
  end
end
