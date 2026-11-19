defmodule WardrikDaemon.DirectTest do
  use ExUnit.Case, async: true

  import WardrikDaemon.Test

  alias Wardrik.Chat.Direct.Request
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Config
  alias WardrikDaemon.Direct

  setup context do
    store = Wardrik.Store.ETS.new(name: :"store #{context.test}")
    start_supervised!({Wardrik.Store, store})

    context
    |> dirs()
    |> Map.put(:store, Wardrik.Store.scope(store, "wardrik_daemon"))
  end

  defp read(context, text) do
    write(context, "config.yaml", text)

    context.env
    |> WardrikDaemon.Dirs.new()
    |> Config.read(context.env)
  end

  defp request,
    do: %Request{
      channel: "slack",
      workspace: "T1",
      principal: %Wardrik.Principal{id: "acme/@ana"}
    }

  test "answers a channel's direct messages with the agent it names, in the org it serves",
       context do
    assert {:ok, config} =
             read(context, """
             org: acme
             orgs: {growth: {channels: [team]}}
             channels:
               slack: {type: slack, token: x, direct: assistant}
               team: {type: slack, token: x, direct: assistant}
               quiet: {type: slack, token: x}
             """)

    {:ok, acme} =
      AgentRecords.create(context.store, owner: "acme", name: "assistant", source: :file)

    {:ok, growth} =
      AgentRecords.create(context.store, owner: "growth", name: "assistant", source: :file)

    channels =
      config.channels
      |> Direct.place(%{wardrik: :w, store: context.store}, config.org)
      |> Map.new()

    assert {WardrikSlack, quiet} = channels["quiet"]
    refute Keyword.has_key?(quiet, :direct)

    agent = fn name ->
      {WardrikSlack, opts} = channels[name]
      {module, direct} = Keyword.fetch!(opts, :direct)
      module.agent(request(), direct)
    end

    assert agent.("slack") == {:ok, acme.id}
    assert agent.("team") == {:ok, growth.id}
  end

  test "says when the agent it names isn't there", context do
    opts = [name: "assistant", store: context.store, org: "acme"]

    assert Direct.agent(request(), opts) ==
             {:error, "There's no agent assistant to answer direct messages."}
  end

  test "makes each member an agent of their own from the one direct names, once", context do
    write(context, "config.yaml", """
    org: acme
    http: {port: #{free_port()}}
    web: {enabled: false}
    defaults: {model: #{model()}}
    channels: {slack: {type: slack, token: x, signing_secret: x}}
    """)

    write(context, "agents/assistant.md", """
    ---
    description: Helps.
    channels: [slack]
    triggers: [{name: daily, every: 1d, prompt: Look around.}]
    ---
    You help.
    """)

    context = start_daemon(context)
    opts = [name: "assistant", store: context.daemon_store, wardrik: context.wardrik, org: "acme"]

    assert {:ok, id} = Direct.Members.agent(request(), opts)
    assert {:ok, ^id} = Direct.Members.agent(request(), opts)

    assert {:ok, %{owner: "acme/@ana", name: "assistant.ana"}} =
             AgentRecords.fetch(context.daemon_store, id)

    assert {:ok, %{"definition" => definition}} =
             Wardrik.run(context.admin, "agent.definition", %{"agent" => id})

    assert %{"description" => "Helps.", "channels" => ["slack"]} = definition
    refute Map.has_key?(definition, "triggers")

    {:ok, assistant} = AgentRecords.fetch_by_name(context.daemon_store, "acme", "assistant")

    assert {:ok, %{"definition" => %{"triggers" => [_daily]}}} =
             Wardrik.run(context.admin, "agent.definition", %{"agent" => assistant.id})

    admin = %{request() | principal: %Wardrik.Principal{id: "admin"}}
    assert Direct.Members.agent(admin, opts) == {:ok, assistant.id}
  end

  test "reads an agent per member from config.yaml", context do
    assert {:ok, config} =
             read(
               context,
               "channels: {slack: {type: slack, token: x, direct: {agent: assistant, per: member}}}"
             )

    assert {WardrikSlack, opts} = Map.new(config.channels)["slack"]
    assert opts[:direct] == {Direct.Members, name: "assistant"}

    assert {:error, why} =
             read(
               context,
               "channels: {slack: {type: slack, token: x, direct: {agent: assistant, per: room}}}"
             )

    assert why =~ "per: member"
  end

  test "refuses a name no agent could have", context do
    assert {:error, why} =
             read(context, "channels: {slack: {type: slack, token: x, direct: \"a b\"}}")

    assert why =~ "channels.slack"
    assert why =~ "is an agent's name"
  end
end
