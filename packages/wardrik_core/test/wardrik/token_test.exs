defmodule Wardrik.TokenTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Principal
  alias Wardrik.Role
  alias Wardrik.Statement
  alias Wardrik.Token

  import Wardrik.AgentID, only: [sigil_A: 2]

  @acme Prefix.new!(org: "acme")
  @maria Principal.new(:user, "maria")

  defp token(roles, prefix \\ @acme),
    do: %Token{principal: @maria, scope: [Role.bind(roles, prefix)]}

  test "a statement reaches the agents its resources cover" do
    statement = Role.bind([:reader], @acme)

    assert Statement.reaches?(statement, ~A"acme/triage")
    refute Statement.reaches?(statement, ~A"acme/@jon/triage")
    refute Statement.reaches?(statement, ~A"globex/triage")
    refute Statement.reaches?(statement, ~A"acmecorp/triage")
    assert Statement.reaches?(statement, Prefix.parse!("acme/triage"))
    refute Statement.reaches?(statement, Prefix.all())

    one = Role.bind([:reader], Prefix.of(~A"acme/@jon/triage"))
    assert Statement.reaches?(one, ~A"acme/@jon/triage/t1")
    refute Statement.reaches?(one, ~A"acme/@jon/triage2")
  end

  test "a statement allows the actions it names, and those under a wildcard" do
    on_one = %Statement{actions: ["agent.*"], resources: [@acme]}

    assert Statement.allows?(on_one, "agent.ask")
    assert Statement.allows?(on_one, "agent.trigger.set")
    refute Statement.allows?(on_one, "agents.list")
    assert Statement.allows?(Role.bind([:owner], @acme), "deployment.nodes")
    refute Statement.allows?(Role.bind([:reader], @acme), "agent.ask")
  end

  test "a role is a named set of actions, and binding several unites them" do
    assert Role.actions(:approver) == ["agent.decide", "agent.authorization.read"]

    assert %Statement{actions: actions, resources: [@acme]} =
             Role.bind([:reader, :messenger, :reader], @acme)

    assert actions == Enum.uniq(Role.actions(:reader) ++ Role.actions(:messenger))
    assert Role.parse(["reader", "worker"]) == {:ok, [:reader, :worker]}

    assert Role.parse(["reader", "admin"]) ==
             {:error,
              ~s("admin" is not a role; the roles are reader, messenger, approver, definer, worker, owner)}
  end

  test "authorizes an action it allows, forbids one it reaches without, and finds nothing else" do
    token = token([:reader])

    assert Token.authorize(token, "agent.read", ~A"acme/triage") == :ok

    assert {:error,
            %Error{
              type: :forbidden,
              message: "This token does not allow agent.define on acme/triage."
            }} =
             Token.authorize(token, "agent.define", ~A"acme/triage")

    assert {:error, %Error{type: :not_found, message: "No agent runs under globex/triage."}} =
             Token.authorize(token, "agent.read", ~A"globex/triage")

    assert Token.authorize(token, "agents.list", Prefix.parse!("acme/triage")) == :ok

    assert {:error, %Error{type: :not_found}} =
             Token.authorize(token, "agents.list", Prefix.all())

    assert {:error, %Error{type: :not_found}} =
             Token.authorize(%Token{principal: @maria}, "agent.read", ~A"acme/triage")
  end

  test "an expired token is unauthorized, whatever it allows" do
    expired = %{Token.root(@maria) | expires: DateTime.add(DateTime.utc_now(), -1)}
    later = %{Token.root(@maria) | expires: DateTime.add(DateTime.utc_now(), 60)}

    assert {:error, %Error{type: :unauthorized}} =
             Token.authorize(expired, "agent.read", ~A"acme/triage")

    assert Token.expired?(expired)
    refute Token.expired?(later)
    assert Token.authorize(later, "agent.read", ~A"acme/triage") == :ok
  end

  test "root holds owner on every agent" do
    root = Token.root(@maria)

    assert Token.authorize(root, "deployment.reload", Prefix.all()) == :ok
    assert Token.authorize(root, "agent.serve", ~A"anyone/@at/all") == :ok
    assert Token.resources(root) == [Prefix.all()]
  end

  describe "assuming a token" do
    test "allows only what both allow, and names who acts last" do
      agent = Principal.new(:agent, "acme/front")
      own = [Role.bind([:reader, :messenger, :definer], @acme)]
      asker = %Token{principal: @maria, scope: [Role.bind([:reader], Prefix.tenant!("acme"))]}

      assumed = Token.assume(asker, agent, scope: own)

      assert assumed.principal == @maria
      assert assumed.assumed_by == [agent]
      assert Token.actor(assumed) == agent
      assert Token.actor(asker) == @maria
      assert Token.authorize(assumed, "agent.read", ~A"acme/triage") == :ok

      assert {:error, %Error{type: :forbidden}} =
               Token.authorize(assumed, "agent.ask", ~A"acme/triage")

      assert {:error, %Error{type: :not_found}} =
               Token.authorize(assumed, "agent.read", ~A"acme/@jon/triage")
    end

    test "never allows more than the token it narrows" do
      agent = Principal.new(:agent, "acme/front")
      one = %Token{principal: @maria, scope: [Role.bind([:reader], Prefix.of(~A"acme/triage"))]}

      assumed = Token.assume(one, agent, scope: [Role.bind([:owner], Prefix.all())])

      assert assumed.scope == one.scope

      assert Token.assume(one, agent, scope: [Role.bind([:owner], Prefix.new!(org: "globex"))]).scope ==
               []
    end

    test "keeps the earlier expiry" do
      soon = DateTime.add(DateTime.utc_now(:second), 60)
      later = DateTime.add(soon, 60)
      token = %{Token.root(@maria) | expires: soon}
      agent = Principal.new(:agent, "acme/front")

      assert Token.assume(token, agent, scope: token.scope).expires == soon
      assert Token.assume(token, agent, scope: token.scope, expires: later).expires == soon
      assert Token.assume(Token.root(@maria), agent, scope: [], expires: later).expires == later
    end
  end

  test "an issuer that names none issues a token allowing nothing" do
    token = Wardrik.Issuer.issue(%Wardrik.Issuer.None{}, @maria, [])

    assert %Token{principal: @maria, scope: [], policy: [], assumed_by: [], expires: :infinity} =
             token
  end
end
