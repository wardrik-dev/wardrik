defmodule WardrikDaemon.AccessTest do
  use ExUnit.Case, async: false
  use Mimic

  import WardrikDaemon.Test

  alias WardrikDaemon.Client
  alias WardrikDaemon.Tokens

  setup :set_mimic_global

  setup context do
    context = dirs(context)
    port = free_port()

    write(context, "config.yaml", """
    org: payments
    orgs: {growth: {}}
    http: {port: #{port}}
    defaults: {model: #{model()}}
    roles:
      reader: {rules: [{verbs: [read, events], kinds: [agent]}]}
    bindings:
      - {org: payments, role: operator, subjects: [user:ana, user:payments/@ana]}
      - {org: payments, role: reader, subjects: [agent:helper]}
      - {org: growth, role: operator, subjects: [user:gus]}
    workspace: {shared: {notes: {read: [reader]}}}
    """)

    write(context, "agents/triage.md", "---\ndescription: Triages.\n---\nYou triage.\n")
    context = start_daemon(context)

    Map.merge(context, %{
      url: "http://127.0.0.1:#{port}",
      triage: id(context, "payments", "triage"),
      growth: agent(context, "growth", "triage")
    })
  end

  defp client(context, subject) do
    {:ok, %{secret: secret}} =
      Tokens.create(context.daemon_store,
        name: "test",
        subject: subject,
        expires: DateTime.add(DateTime.utc_now(), 1, :hour)
      )

    %Client{url: context.url, secret: secret}
  end

  defp find(client, owner, name),
    do: Client.run(client, "agents.find", %{"owner" => owner, "name" => name})

  test "a user bound in one org reaches nothing in another, nor the deployment", context do
    ana = client(context, "user:ana")

    assert {:ok, _agent} = Client.run(ana, "agent.read", %{"agent" => context.triage})

    assert {:error, "not_found", _message} =
             Client.run(ana, "agent.read", %{"agent" => context.growth})

    assert {:error, "not_found", _message} =
             Client.run(ana, "agent.forget", %{"agent" => context.growth})

    assert {:error, "not_found", _message} = Client.run(ana, "deployment.reload", %{})
    assert {:ok, %{"agents" => agents}} = Client.run(ana, "agents.list", %{})
    assert for(agent <- agents, do: agent["id"]) == [context.triage]

    admin = %Client{ana | secret: "wdk_nope_nope"}
    assert {:error, "unauthorized", _message} = Client.run(admin, "agents.list", %{})
  end

  test "two orgs may use one name, and each finds its own alone", context do
    ana = client(context, "user:ana")
    gus = client(context, "user:gus")
    admin = client(context, "user:admin")

    assert context.triage != context.growth

    assert {:ok, %{"agents" => [%{"id" => triage, "org" => "payments", "owner" => "payments"}]}} =
             find(ana, "payments", "triage")

    assert triage == context.triage
    assert find(ana, "payments/@ana", "triage") == find(ana, "payments", "triage")
    assert {:ok, %{"agents" => [%{"id" => growth}]}} = find(gus, "growth", "triage")
    assert growth == context.growth

    assert find(ana, "growth", "triage") == {:ok, %{"agents" => []}}
    assert find(gus, "payments", "triage") == {:ok, %{"agents" => []}}

    assert {:ok, %{"agents" => [%{"name" => "triage", "org" => "growth"}]}} =
             Client.run(admin, "agents.find", %{"owner" => "growth"})

    assert {:error, "not_found", _message} = find(ana, "globex", "triage")
    assert {:error, "invalid_request", _message} = find(ana, "payments/x/y", "triage")

    for {client, id} <- [{ana, context.growth}, {gus, context.triage}] do
      assert {:error, "not_found", _message} = Client.run(client, "agent.read", %{"agent" => id})

      assert {:error, "not_found", _message} =
               Client.run(client, "agent.ask", %{"agent" => id, "content" => "Hi"})
    end
  end

  test "defines only an agent its owner's route made, with an ID the daemon minted", context do
    ana = client(context, "user:payments/@ana")
    admin = client(context, "user:admin")
    unminted = "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN"

    for client <- [ana, admin] do
      assert {:error, "not_found", _message} =
               Client.run(client, "agent.define", %{"agent" => unminted, "model" => model()})
    end

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Agent.define(context.admin, unminted, model: model())

    made = %{"owner" => "payments/@ana", "name" => "notes", "model" => model()}

    assert {:ok, %{"id" => "agt_" <> _ulid = id, "org" => "payments", "owner" => "payments/@ana"}} =
             Client.run(ana, "agents.create", made)

    assert {:ok, %{"agent" => %{"id" => ^id}}} = Client.run(ana, "agent.read", %{"agent" => id})
    assert {:ok, _defined} = Client.run(ana, "agent.define", %{"agent" => id, "model" => model()})
    assert {:error, "conflict", _message} = Client.run(admin, "agents.create", made)

    for owner <- ["growth", "deployment"] do
      assert {:error, "not_found", _message} =
               Client.run(ana, "agents.create", %{made | "owner" => owner})
    end

    for refused <- [
          %{made | "owner" => "deployment"},
          %{made | "name" => "a/b"},
          Map.merge(made, %{"name" => "odd", "colour" => "red"})
        ] do
      assert {:error, "invalid_request", _message} = Client.run(admin, "agents.create", refused)
    end

    assert find(admin, "payments", "odd") == {:ok, %{"agents" => []}}

    shares = %{"name" => "reader", "workspace" => %{"shared" => %{"team" => "notes"}}}

    assert {:ok, %{"id" => reader}} =
             Client.run(admin, "agents.create", Map.merge(made, shares))

    assert {:ok, %{"definition" => %{"workspace" => %{"shared" => %{"team" => ^id}}}}} =
             Client.run(admin, "agent.definition", %{"agent" => reader})

    assert {:error, "invalid_request", message} =
             Client.run(
               admin,
               "agents.create",
               Map.merge(made, %{shares | "name" => "far"}) |> Map.put("owner", "growth")
             )

    assert message =~ "workspace.shared.team: names no agent of growth"

    assert {:ok, nil} = Client.run(admin, "agent.forget", %{"agent" => id})
    assert {:ok, %{"id" => again}} = Client.run(ana, "agents.create", made)
    assert again != id
  end

  test "an agent gets its own role, not its owner's", context do
    helper = agent(context, "payments/@ana", "helper")
    owner = Wardrik.as(context.wardrik, "payments/@ana")
    acting = Wardrik.as(context.wardrik, "payments/@ana", actor: {:agent, helper})
    other = agent(context, "payments/@ana", "other")
    defined = %{"agent" => other, "model" => model()}

    assert {:ok, _definition, _problems} = Wardrik.Agent.definition(acting, context.triage)

    for {action, input} <- [
          {"agent.define", defined},
          {"agent.ask", %{"agent" => context.triage, "content" => "Hi"}}
        ] do
      assert {:error, %Wardrik.Error{type: :forbidden}} = Wardrik.run(acting, action, input)
    end

    assert {:ok, _snapshot} = Wardrik.run(owner, "agent.define", defined)

    token = client(context, "agent:" <> helper)

    assert {:error, "forbidden", _message} = Client.run(token, "agent.define", defined)
    assert {:ok, _agent} = Client.run(token, "agent.read", %{"agent" => context.triage})

    assert {:error, "not_found", _message} =
             Client.run(token, "agent.read", %{"agent" => context.growth})
  end

  test "a conversation is reached through its agent alone", context do
    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      message = ReqLLM.Context.assistant("Done.")
      {:ok, %ReqLLM.Response{id: "resp", model: "test", context: nil, message: message}}
    end)

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)

    {:ok, %Wardrik.Reply{}} =
      Wardrik.Agent.reply(context.admin, context.growth, "Hi", conversation: "C1")

    ana = client(context, "user:ana")
    gus = client(context, "user:gus")
    conversation = %{"agent" => context.growth, "conversation" => "C1"}

    assert {:ok, %{"events" => [_ | _]}} = Client.run(gus, "agent.events", conversation)
    assert {:ok, %{"conversation" => "C1"}} = Client.run(gus, "agent.read", conversation)

    for operation <- ["agent.events", "agent.read", "agent.timeline", "agent.cancel"] do
      assert {:error, "not_found", _message} = Client.run(ana, operation, conversation)
    end

    assert {:error, "not_found", _message} =
             Client.run(ana, "agent.approve", Map.put(conversation, "interrupt", "call_1"))

    assert {:ok, %{"agents" => listed}} = Client.run(gus, "agents.list", %{})
    assert %{"id" => growth} = Enum.find(listed, &(&1["conversation"] == "C1"))
    assert growth == context.growth

    assert {:ok, %{"agents" => listed}} = Client.run(ana, "agents.list", %{})
    refute Enum.any?(listed, &(&1["id"] == context.growth))
    assert {:ok, %{"interrupts" => []}} = Client.run(ana, "interrupts.list", %{})
    assert {:ok, %{"events" => events}} = Client.run(ana, "events.list", %{})
    refute Enum.any?(events, &(&1["agent"] == context.growth))
    assert {:ok, %{"events" => events}} = Client.run(gus, "events.list", %{})
    assert Enum.any?(events, &(&1["conversation"] == "C1"))
  end
end
