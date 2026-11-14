defmodule WardrikDaemon.AuthorizerTest do
  use ExUnit.Case, async: true

  alias Wardrik.Authorizer.Request
  alias Wardrik.Principal
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Authorizer
  alias WardrikDaemon.Config.Access

  # Agents by owner and name, as "payments/triage" or "payments/@ana/notes". Each gets a record.
  @agents ~w(payments/triage payments/other payments/@ana/notes payments/@ana/helper growth/triage
             growth/a growth/other growth/x growth/@jon/notes growth/@ana/memo growth/helper)

  setup context do
    {:ok, access} =
      Access.read(
        %{
          "reader" => %{"rules" => [%{"verbs" => ["read", "events"], "kinds" => ["agent"]}]},
          "triager" => %{
            "rules" => [
              %{"verbs" => ["ask"], "kinds" => ["agent"], "names" => ["triage"]}
            ]
          },
          "maker" => %{"rules" => [%{"verbs" => ["create"], "kinds" => ["agent"]}]},
          "named_maker" => %{
            "rules" => [%{"verbs" => ["create"], "kinds" => ["agent"], "names" => ["triage"]}]
          }
        },
        [
          %{
            "org" => "payments",
            "role" => "operator",
            "subjects" => ["user:payments/@ana"]
          },
          %{
            "org" => "payments",
            "role" => "reader",
            "subjects" => ["agent:helper"]
          },
          %{"org" => "growth", "role" => "reader", "subjects" => ["group:growth-eng"]},
          %{"org" => "payments", "role" => "reader", "subjects" => ["user:payments/@dee"]},
          %{"org" => "growth", "role" => "triager", "subjects" => ["user:growth/@bo"]},
          %{"org" => "growth", "role" => "maker", "subjects" => ["user:growth/@lee"]},
          %{"org" => "growth", "role" => "named_maker", "subjects" => ["user:growth/@mo"]}
        ],
        ["payments", "growth"]
      )

    store = Wardrik.Store.ETS.new(name: :"store #{context.test}")
    start_supervised!({Wardrik.Store, store})
    store = Wardrik.Store.scope(store, "wardrik_daemon")

    ids =
      Map.new(@agents, fn agent ->
        {owner, name} =
          case String.split(agent, "/") do
            [org, person, name] -> {org <> "/" <> person, name}
            [org, name] -> {org, name}
          end

        {:ok, record} = AgentRecords.create(store, owner: owner, name: name, source: :api)
        {agent, record.id}
      end)

    %{access: %{access: access, store: store, ids: ids}}
  end

  defp decide(%{ids: ids} = opts, fields) do
    {principal, fields} = Keyword.pop(fields, :principal)
    {attributes, fields} = Keyword.pop(fields, :attributes, %{})

    fields =
      fields
      |> Keyword.update(:resource, nil, &minted(&1, ids))
      |> Keyword.update(:actor, nil, &minted(&1, ids))

    request =
      struct!(
        Request,
        [principal: %Principal{id: principal, attributes: attributes}, scope: nil] ++ fields
      )

    Authorizer.authorize(request, Map.take(opts, [:access, :store]))
  end

  defp minted({:agent, agent}, ids), do: {:agent, Map.get(ids, agent, agent)}
  defp minted(other, _ids), do: other

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

      assert decide(access,
               principal: "payments/@ana",
               action: action,
               resource: {kind, "payments/@bo"}
             ) ==
               :ok

      assert decide(access,
               principal: "payments/@ana",
               action: action,
               resource: {kind, "growth"}
             ) ==
               {:error, :not_found}
    end
  end

  test "reaches tokens only through a binding in every org, never as their owner", %{
    access: access
  } do
    for {principal, resource} <- [
          {"payments/@ana", {:token, "user:payments/@ana"}},
          {"user:payments/@ana", {:token, "user:payments/@ana"}}
        ] do
      assert decide(access, principal: principal, action: "token.create", resource: resource) ==
               {:error, :not_found}
    end

    assert decide(access,
             principal: "admin",
             action: "token.create",
             resource: {:token, "user:payments/@x"}
           ) ==
             :ok

    for {principal, actor} <- [
          {"payments/@ana", nil},
          {"admin", {:agent, "payments/@ana/helper"}}
        ] do
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
      assert decide(access,
               principal: "payments/@ana",
               action: action,
               resource: {:agent, "growth/triage"}
             ) ==
               {:error, :not_found}
    end

    assert decide(access,
             principal: "payments/@ana",
             action: "secret.put",
             resource: {:provider, "growth"}
           ) ==
             {:error, :not_found}

    assert decide(access,
             principal: "payments/@ana",
             action: "secret.put",
             resource: {:provider, "payments"}
           ) ==
             :ok
  end

  test "groups, names and verbs narrow a binding", %{access: access} do
    grouped = [principal: "growth/@cy", attributes: %{groups: ["growth-eng"]}]

    assert decide(access, grouped ++ [action: "agent.events", resource: {:agent, "growth/a"}]) ==
             :ok

    assert decide(access, grouped ++ [action: "agent.ask", resource: {:agent, "growth/a"}]) ==
             {:error, :forbidden}

    assert decide(access,
             principal: "growth/@cy",
             action: "agent.read",
             resource: {:agent, "growth/a"}
           ) ==
             {:error, :not_found}

    assert decide(access,
             principal: "growth/@bo",
             action: "agent.ask",
             resource: {:agent, "growth/triage"}
           ) ==
             :ok

    assert decide(access,
             principal: "growth/@bo",
             action: "agent.ask",
             resource: {:agent, "growth/other"}
           ) ==
             {:error, :forbidden}
  end

  test "an owner may do anything to its own, acting itself", %{access: access} do
    jon = [principal: "growth/@jon"]

    for {action, resource} <- [
          {"agent.define", {:agent, "growth/@jon/notes"}},
          {"agent.forget", {:agent, "growth/@jon/notes"}},
          {"agent.create", {:agents, "growth/@jon"}},
          {"provider.add", {:provider, "growth/@jon"}}
        ],
        do: assert(decide(access, jon ++ [action: action, resource: resource]) == :ok)

    assert decide(access, jon ++ [action: "agent.ask", resource: {:agent, "growth/@ana/memo"}]) ==
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
    assert secret.("payments/@ana", "payments") == :ok
    assert secret.("payments/@ana", "payments/@bo") == :ok
    assert secret.("payments/@ana", "growth") == {:error, :not_found}
    assert secret.("deployment", "deployment") == {:error, :not_found}
    assert secret.("payments/@ana", "deployment") == {:error, :not_found}
    assert secret.("admin", "deployment") == :ok

    ceiling = [action: "ceiling.read", resource: {:ceiling, "payments"}]
    assert decide(access, [principal: "payments/@ana"] ++ ceiling) == :ok
    assert decide(access, [principal: "payments"] ++ ceiling) == {:error, :not_found}

    assert decide(access,
             principal: "payments/@ana",
             action: "ceiling.read",
             resource: {:ceiling, "growth"}
           ) ==
             {:error, :not_found}
  end

  test "the deployment needs a binding in every org", %{access: access} do
    for principal <- ["payments/@ana", "payments"] do
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
             principal: "payments/@ana",
             actor: {:worker, "w1"},
             action: "agent.read",
             resource: {:agent, "payments/triage"}
           ) == {:error, :not_found}

    assert decide(access,
             principal: "payments/@ana",
             action: "agent.read",
             resource: {:agent, "nope"}
           ) ==
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

  test "an agent the daemon didn't mint reaches no one, the admin included", %{access: access} do
    for principal <- ["admin", "payments/@ana", "payments"],
        action <- ["agent.define", "agent.read"] do
      assert decide(access,
               principal: principal,
               action: action,
               resource: {:agent, "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN"}
             ) == {:error, :not_found}
    end
  end

  test "making an agent is create on the kind agent, in the owner's org", %{access: access} do
    create = fn principal, owner ->
      decide(access, principal: principal, action: "agent.create", resource: {:agents, owner})
    end

    assert create.("growth/@jon", "growth/@jon") == :ok
    assert create.("growth/@jon", "growth") == {:error, :not_found}
    assert create.("growth/@lee", "growth") == :ok
    assert create.("growth/@lee", "growth/@jon") == :ok
    assert create.("growth/@lee", "payments") == {:error, :not_found}
    assert create.("growth/@mo", "growth") == {:error, :forbidden}
    assert create.("growth/@bo", "growth") == {:error, :forbidden}
    assert create.("payments/@ana", "deployment") == {:error, :not_found}
  end

  test "a binding names an agent in its own org alone", %{access: access} do
    read = [action: "agent.read", resource: {:agent, "payments/triage"}]
    helper = [principal: "payments/@ana", actor: {:agent, "payments/@ana/helper"}]

    assert decide(access, helper ++ read) == :ok

    assert decide(access, [principal: "growth", actor: {:agent, "growth/helper"}] ++ read) ==
             {:error, :not_found}
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

      assert decide(access, member("payments/@dee", %{}) ++ decision) == {:error, :forbidden}

      assert decide(access, member("payments/@dee", %{asked_by: "payments/@ana"}) ++ decision) ==
               {:error, :forbidden}

      assert decide(access, member("payments/@dee", %{asked_by: "payments/@dee"}) ++ decision) ==
               :ok

      assert decide(access, member("payments/@ana", %{}) ++ decision) == :ok
      assert decide(access, member("growth/@cy", %{}) ++ decision) == {:error, :not_found}

      assert decide(access, member("growth/@cy", %{approver: true}) ++ decision) ==
               {:error, :not_found}
    end

    test "a member asks and reads as their user's bindings allow", %{access: access} do
      read = [action: "agent.read", resource: {:agent, "payments/triage"}]
      ask = [action: "agent.ask", resource: {:agent, "payments/triage"}]

      assert decide(access, member("payments/@dee", %{}) ++ read) == :ok
      assert decide(access, member("payments/@dee", %{}) ++ ask) == {:error, :forbidden}
      assert decide(access, member("payments/@ana", %{}) ++ ask) == :ok
      assert decide(access, member("growth/@cy", %{}) ++ read) == {:error, :not_found}

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
               member("payments/@ana", %{}) ++
                 [action: "agent.define", resource: {:agent, "payments/triage"}]
             ) == {:error, :forbidden}

      growth = [action: "agent.ask", resource: {:agent, "growth/triage"}]
      assert decide(access, member("growth/@bo", %{}) ++ growth) == {:error, :not_found}
      assert decide(access, member("growth/@bo", %{}, "growth") ++ growth) == :ok
      assert decide(access, member("growth/@bo", %{}, "*") ++ growth) == :ok

      assert decide(
               access,
               member("payments/@ana", %{}) ++
                 [action: "secret.put", resource: {:provider, "payments"}]
             ) == {:error, :not_found}

      assert decide(
               access,
               member("payments/@ana", %{}, "payments/@ana") ++
                 [action: "agent.ask", resource: {:agent, "payments/triage"}]
             ) == {:error, :not_found}
    end

    test "the channel acting for itself is the installation's owner", %{access: access} do
      read = [action: "agent.read", resource: {:agent, "payments/triage"}]

      assert decide(access, member("payments", %{}) ++ read) == :ok
      assert decide(access, member("growth", %{}, "growth") ++ read) == {:error, :not_found}
    end
  end

  test "a binding in deployment reaches the deployment, and names agents of its own org", %{
    access: access
  } do
    {:ok, deployment} =
      Access.read(
        %{"observer" => %{"rules" => [%{"verbs" => ["*"], "kinds" => ["deployment", "token"]}]}},
        [%{"org" => "deployment", "role" => "observer", "subjects" => ["agent:triage"]}],
        ["payments", "growth"],
        "payments"
      )

    opts = %{access | access: deployment}
    home = [principal: "payments", actor: {:agent, "payments/triage"}]
    elsewhere = [principal: "growth", actor: {:agent, "growth/triage"}]

    for action <- ["deployment.nodes", "deployment.runtime", "deployment.audit"] do
      assert decide(opts, home ++ [action: action, resource: {:deployment, "nodes"}]) == :ok

      assert decide(opts, elsewhere ++ [action: action, resource: {:deployment, "nodes"}]) ==
               {:error, :not_found}
    end

    # Tokens stay out of reach of every binding but one in "*".
    assert decide(
             opts,
             home ++ [action: "token.create", resource: {:token, "user:payments/@ana"}]
           ) ==
             {:error, :not_found}

    # And it reaches nothing of an org's.
    assert decide(opts, home ++ [action: "agent.read", resource: {:agent, "payments/other"}]) ==
             {:error, :not_found}
  end
end
