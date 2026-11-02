defmodule WardrikDaemon.AuthorizerTest do
  use ExUnit.Case, async: true

  alias Wardrik.Authorizer.Request
  alias WardrikCore.Principal
  alias WardrikDaemon.Authorizer
  alias WardrikDaemon.Config.Access

  setup do
    {:ok, access} =
      Access.read(
        %{
          "reader" => %{"rules" => [%{"verbs" => ["read", "events"], "kinds" => ["agent"]}]},
          "triager" => %{
            "rules" => [
              %{"verbs" => ["ask"], "kinds" => ["agent"], "names" => ["growth/triage"]}
            ]
          }
        },
        [
          %{
            "org" => "payments",
            "role" => "operator",
            "subjects" => ["user:ana", "user:payments/@ana"]
          },
          %{
            "org" => "payments",
            "role" => "reader",
            "subjects" => ["agent:payments/@ana/helper"]
          },
          %{"org" => "growth", "role" => "reader", "subjects" => ["group:growth-eng"]},
          %{"org" => "payments", "role" => "reader", "subjects" => ["user:dee"]},
          %{"org" => "growth", "role" => "triager", "subjects" => ["user:bo"]}
        ],
        ["payments", "growth"]
      )

    %{access: access}
  end

  defp decide(access, fields) do
    {principal, fields} = Keyword.pop(fields, :principal)
    {attributes, fields} = Keyword.pop(fields, :attributes, %{})

    request =
      struct!(
        Request,
        [principal: %Principal{id: principal, attributes: attributes}, scope: nil] ++ fields
      )

    Authorizer.authorize(request, access)
  end

  test "an agent gets its own bindings, never its owner's", %{access: access} do
    owner = [principal: "payments/@ana"]
    agent = [principal: "payments/@ana", actor: {:agent, "payments/@ana/helper"}]

    assert decide(access, agent ++ [action: "agent.read", resource: {:agent, "payments/other"}]) ==
             :ok

    for action <- ["agent.define", "agent.ask", "agent.forget"],
        id <- ["payments/other", "payments/@ana/notes"] do
      assert decide(access, owner ++ [action: action, resource: {:agent, id}]) == :ok

      assert decide(access, agent ++ [action: action, resource: {:agent, id}]) ==
               {:error, :forbidden}
    end
  end

  test "an owner holds its own servers and notify targets, and no one else's", %{access: access} do
    for kind <- [:mcp_server, :notify_target], action <- ["#{kind}.add", "#{kind}.read"] do
      assert decide(access,
               principal: "growth/@cy",
               action: action,
               resource: {kind, "growth/@cy"}
             ) ==
               :ok

      for theirs <- ["growth", "growth/@dee", "deployment"] do
        assert decide(access, principal: "growth/@cy", action: action, resource: {kind, theirs}) ==
                 {:error, :not_found}
      end

      assert decide(access, principal: "ana", action: action, resource: {kind, "payments/@bo"}) ==
               :ok

      assert decide(access, principal: "ana", action: action, resource: {kind, "growth"}) ==
               {:error, :not_found}
    end
  end

  test "reaches tokens only through a binding in every org, never as their owner", %{
    access: access
  } do
    for {principal, resource} <- [
          {"ana", {:token, "user:ana"}},
          {"user:ana", {:token, "user:ana"}}
        ] do
      assert decide(access, principal: principal, action: "token.create", resource: resource) ==
               {:error, :not_found}
    end

    assert decide(access,
             principal: "admin",
             action: "token.create",
             resource: {:token, "user:x"}
           ) ==
             :ok

    for {principal, actor} <- [{"ana", nil}, {"admin", {:agent, "payments/@ana/helper"}}] do
      assert decide(access,
               principal: principal,
               actor: actor,
               action: "token.create",
               resource: {:token, "user:admin"}
             ) == {:error, :forbidden}
    end

    assert decide(access,
             principal: "admin",
             action: "token.create",
             resource: {:token, "user:admin"}
           ) == :ok
  end

  test "a binding in one org reaches nothing in another", %{access: access} do
    for action <- ["agent.read", "agent.define"] do
      assert decide(access, principal: "ana", action: action, resource: {:agent, "growth/triage"}) ==
               {:error, :not_found}
    end

    assert decide(access, principal: "ana", action: "secret.put", resource: {:provider, "growth"}) ==
             {:error, :not_found}

    assert decide(access,
             principal: "ana",
             action: "secret.put",
             resource: {:provider, "payments"}
           ) ==
             :ok
  end

  test "groups, names and verbs narrow a binding", %{access: access} do
    grouped = [principal: "cy", attributes: %{groups: ["growth-eng"]}]

    assert decide(access, grouped ++ [action: "agent.events", resource: {:agent, "growth/a"}]) ==
             :ok

    assert decide(access, grouped ++ [action: "agent.ask", resource: {:agent, "growth/a"}]) ==
             {:error, :forbidden}

    assert decide(access, principal: "cy", action: "agent.read", resource: {:agent, "growth/a"}) ==
             {:error, :not_found}

    assert decide(access,
             principal: "bo",
             action: "agent.ask",
             resource: {:agent, "growth/triage"}
           ) ==
             :ok

    assert decide(access,
             principal: "bo",
             action: "agent.ask",
             resource: {:agent, "growth/other"}
           ) ==
             {:error, :forbidden}
  end

  test "an owner may do anything to its own, acting itself", %{access: access} do
    jon = [principal: "growth/@jon"]

    for {action, resource} <- [
          {"agent.define", {:agent, "growth/@jon/notes"}},
          {"agent.forget", {:agent, "growth/@jon/notes/C1"}},
          {"provider.add", {:provider, "growth/@jon"}}
        ],
        do: assert(decide(access, jon ++ [action: action, resource: resource]) == :ok)

    assert decide(access, jon ++ [action: "agent.ask", resource: {:agent, "growth/@ana/notes"}]) ==
             {:error, :not_found}

    assert decide(access,
             principal: "deployment",
             action: "secret.put",
             resource: {:provider, "deployment"}
           ) ==
             {:error, :not_found}
  end

  test "an owner's secrets are its own, and in its org; the deployment's need every org",
       %{access: access} do
    secret = fn principal, owner ->
      decide(access, principal: principal, action: "secret.put", resource: {:secret, owner})
    end

    assert secret.("growth/@jon", "growth/@jon") == :ok
    assert secret.("growth/@jon", "growth/@ana") == {:error, :not_found}
    assert secret.("growth/@jon", "growth") == {:error, :not_found}
    assert secret.("ana", "payments") == :ok
    assert secret.("ana", "payments/@bo") == :ok
    assert secret.("ana", "growth") == {:error, :not_found}
    assert secret.("deployment", "deployment") == {:error, :not_found}
    assert secret.("ana", "deployment") == {:error, :not_found}
    assert secret.("admin", "deployment") == :ok

    ceiling = [action: "ceiling.read", resource: {:ceiling, "payments"}]
    assert decide(access, [principal: "ana"] ++ ceiling) == :ok
    assert decide(access, [principal: "payments"] ++ ceiling) == {:error, :not_found}

    assert decide(access,
             principal: "ana",
             action: "ceiling.read",
             resource: {:ceiling, "growth"}
           ) ==
             {:error, :not_found}
  end

  test "the deployment needs a binding in every org", %{access: access} do
    for principal <- ["ana", "payments"] do
      assert decide(access,
               principal: principal,
               action: "deployment.reload",
               resource: {:deployment, "deployment"}
             ) ==
               {:error, :not_found}
    end

    assert decide(access,
             principal: "admin",
             action: "deployment.reload",
             resource: {:deployment, "deployment"}
           ) ==
             :ok

    assert decide(access,
             principal: "admin",
             action: "agent.define",
             resource: {:agent, "growth/x"}
           ) ==
             :ok
  end

  test "an actor it doesn't know, or an ID it can't read, reaches nothing", %{access: access} do
    assert decide(access,
             principal: "ana",
             actor: {:worker, "w1"},
             action: "agent.read",
             resource: {:agent, "payments/triage"}
           ) == {:error, :not_found}

    assert decide(access, principal: "ana", action: "agent.read", resource: {:agent, "nope"}) ==
             {:error, :not_found}

    channel = [principal: "U1", actor: {:channel, "slack"}, action: "agent.ask"]

    assert decide(access, channel ++ [resource: {:agent, "payments/triage"}]) ==
             {:error, :not_found}

    assert decide(
             access,
             channel ++
               [
                 resource: {:agent, "nope"},
                 context: %{installation: %{owner: "payments", workspace: "T1"}}
               ]
           ) == {:error, :not_found}
  end

  describe "through a channel" do
    defp member(id, context, owner \\ "payments"),
      do: [
        principal: id,
        actor: {:channel, "slack"},
        context: Map.put(context, :installation, %{owner: owner, workspace: "T1"})
      ]

    test "a member decides as their user: with a binding that allows it, or for what they asked",
         %{access: access} do
      decision = [action: "agent.decide", resource: {:agent, "payments/triage"}]

      assert decide(access, member("dee", %{}) ++ decision) == {:error, :forbidden}
      assert decide(access, member("dee", %{asked_by: "ana"}) ++ decision) == {:error, :forbidden}
      assert decide(access, member("dee", %{asked_by: "dee"}) ++ decision) == :ok
      assert decide(access, member("ana", %{}) ++ decision) == :ok
      assert decide(access, member("cy", %{}) ++ decision) == {:error, :not_found}
      assert decide(access, member("cy", %{approver: true}) ++ decision) == {:error, :not_found}
    end

    test "a member asks and reads as their user's bindings allow", %{access: access} do
      read = [action: "agent.read", resource: {:agent, "payments/triage"}]
      ask = [action: "agent.ask", resource: {:agent, "payments/triage"}]

      assert decide(access, member("dee", %{}) ++ read) == :ok
      assert decide(access, member("dee", %{}) ++ ask) == {:error, :forbidden}
      assert decide(access, member("ana", %{}) ++ ask) == :ok
      assert decide(access, member("cy", %{}) ++ read) == {:error, :not_found}

      assert decide(
               access,
               member("payments/@ana", %{}) ++
                 [action: "agent.ask", resource: {:agent, "payments/@ana/notes"}]
             ) == :ok
    end

    test "reaches only the installation owner's agents, and only to ask, read and decide",
         %{access: access} do
      assert decide(
               access,
               member("ana", %{}) ++
                 [action: "agent.define", resource: {:agent, "payments/triage"}]
             ) == {:error, :forbidden}

      growth = [action: "agent.ask", resource: {:agent, "growth/triage"}]
      assert decide(access, member("bo", %{}) ++ growth) == {:error, :not_found}
      assert decide(access, member("bo", %{}, "growth") ++ growth) == :ok
      assert decide(access, member("bo", %{}, "*") ++ growth) == :ok

      assert decide(
               access,
               member("ana", %{}) ++ [action: "secret.put", resource: {:provider, "payments"}]
             ) == {:error, :not_found}

      assert decide(
               access,
               member("ana", %{}, "payments/@ana") ++
                 [action: "agent.ask", resource: {:agent, "payments/triage"}]
             ) == {:error, :not_found}
    end

    test "the channel acting for itself is the installation's owner", %{access: access} do
      read = [action: "agent.read", resource: {:agent, "payments/triage"}]

      assert decide(access, member("payments", %{}) ++ read) == :ok
      assert decide(access, member("growth", %{}, "growth") ++ read) == {:error, :not_found}
    end
  end
end
