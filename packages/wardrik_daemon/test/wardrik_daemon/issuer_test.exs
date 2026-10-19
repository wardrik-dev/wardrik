defmodule WardrikDaemon.IssuerTest do
  # What config.yaml says of channels, and the agents' defaults, are the
  # node's, which these tests set.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Wardrik.AgentID
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Token
  alias WardrikDaemon.Agents
  alias WardrikDaemon.Test.Host

  setup %{tmp_dir: dir}, do: %{dir: dir}

  # The daemon's issuer, read under the sections the test has put.
  defp issue(principal),
    do: Wardrik.Issuer.issue(Wardrik.Host.issuer(Host.host(Host.agents())), principal, [])

  # The test channel knows people by their id alone, in the one workspace
  # its token reaches.
  defp channel(settings) do
    Host.put_section(
      WardrikChannel,
      Keyword.merge(
        [
          channels: [chat: {WardrikDaemon.Test.Channel, []}],
          installations:
            WardrikChannel.Installations.Config.new([{:chat, "token", Resource.deployment()}])
        ],
        settings
      )
    )
  end

  defp in_chat(user) do
    {:ok, installation} =
      Host.sections()
      |> Keyword.fetch!(WardrikChannel)
      |> Keyword.fetch!(:installations)
      |> WardrikChannel.Installations.fetch("chat", "chat")

    issue(WardrikChannel.principal(WardrikChannel.Member.new(installation, user)))
  end

  # What each statement allows, as the roles it was bound from, on what.
  defp roles(%Token{scope: scope}),
    do:
      for(
        statement <- scope,
        resource <- statement.resources,
        do: {to_string(resource), statement.actions}
      )

  defp bound(roles), do: Wardrik.Role.bind(roles, []).actions

  test "whoever holds the node holds owner on everything" do
    for id <- ~w(shell:jon terminal:jon ssh:jon) do
      jon = Principal.new(id)
      assert %Token{principal: ^jon} = token = issue(jon)
      assert roles(token) == [{"*", ["*"]}]
      assert Token.authorize(token, "agent.define", AgentID.parse!("anyone/@at/all")) == :ok
    end
  end

  test "a person in a channel reads and messages its orgs' agents, and decides only where named" do
    channel(orgs: [chat: ["acme", "globex"]])

    assert roles(in_chat("U1")) == [
             {"acme/agent/*", bound([:reader, :messenger])},
             {"globex/agent/*", bound([:reader, :messenger])}
           ]

    channel(orgs: [chat: :all], approvers: [chat: %WardrikChannel.Approvers.Named{names: ["U2"]}])
    assert roles(in_chat("U1")) == [{"*/agent/*", bound([:reader, :messenger])}]
    assert roles(in_chat("U2")) == [{"*/agent/*", bound([:reader, :messenger, :approver])}]
  end

  test "with approvers: anyone, everyone in the channel decides" do
    channel(orgs: [chat: ["acme"]], approvers: [chat: %WardrikChannel.Approvers.Anyone{}])
    assert roles(in_chat("U1")) == [{"acme/agent/*", bound([:reader, :messenger, :approver])}]
  end

  test "a token on the channel's orgs reaches none of their users' agents" do
    channel(orgs: [chat: ["acme"]])
    token = in_chat("U1")
    assert Token.authorize(token, "agent.read", AgentID.parse!("acme/books")) == :ok
    refute Token.reaches?(token, AgentID.parse!("acme/@bob/assistant"))
  end

  test "the approvers of a notify target posting in the channel decide there" do
    channel(orgs: [chat: ["acme"]])

    Host.put_section(WardrikNotify,
      targets: [
        ops:
          {WardrikChannel.Notices,
           channel: {WardrikDaemon.Test.Channel, []}, room: "#ops", approvers: ["U3"]},
        elsewhere:
          {WardrikChannel.Notices,
           channel: {WardrikDaemon.Test.Channel, [room_prefix: "x"]},
           room: "#x",
           approvers: ["U4"]}
      ]
    )

    assert roles(in_chat("U3")) == [{"acme/agent/*", bound([:reader, :messenger, :approver])}]
    assert roles(in_chat("U4")) == [{"acme/agent/*", bound([:reader, :messenger])}]
  end

  test "an admin defines only under the policy the defaults name", %{dir: dir} do
    channel(
      orgs: [chat: ["acme"]],
      approvers: [chat: %WardrikChannel.Approvers.Named{names: ["U2"]}],
      admins: [chat: ["U1"]]
    )

    assert %Token{policy: :none} = token = in_chat("U1")
    assert roles(token) == [{"acme/agent/*", bound([:reader, :messenger, :approver])}]

    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join([dir, "policies", "careful.yaml"]), "deny: [run_lua]\n")
    Host.put_section(Agents, defaults: %{"policy" => "careful"})
    Host.start_agents(dir)
    _files = Agents.files(Host.agents(), host: Host.host())

    assert %Token{policy: "careful"} = token = in_chat("U1")
    assert roles(token) == [{"acme/agent/*", bound([:reader, :messenger, :approver, :definer])}]
  end

  test "an agent reads and messages its owner's agents" do
    token = issue(Principal.new("acme/agent/front"))
    assert roles(token) == [{"acme/agent/*", bound([:reader, :messenger])}]

    token = issue(Principal.new("acme/agent/front/thread/thread-1"))
    assert roles(token) == [{"acme/agent/*", bound([:reader, :messenger])}]

    token = issue(Principal.new("acme/@jon/agent/assistant"))
    assert roles(token) == [{"acme/@jon/agent/*", bound([:reader, :messenger])}]
  end

  test "a request to a trigger holds nothing" do
    for id <- ["acme/agent/front/trigger/hook", "acme/@jon/agent/front/trigger/hook"],
        do: assert(%Token{scope: []} = issue(Principal.new(id)))
  end

  test "the deployment itself reads every agent's events, and does nothing else" do
    token = issue(Principal.deployment())
    assert roles(token) == [{"*/agent/*", ["agent.events"]}]

    for agent <- ~w(acme/triage acme/@jon/assistant globex/front/thread-1) do
      assert Token.authorize(token, "agent.events", AgentID.parse!(agent)) == :ok
      assert {:error, _reason} = Token.authorize(token, "agent.read", AgentID.parse!(agent))
    end
  end

  test "anyone else holds nothing" do
    channel(orgs: [chat: ["acme"]])

    for id <- ~w(oauth:github slack:T1/U1 acme acme/@jon deployment/server/github acme/server/crm) do
      assert %Token{scope: []} = issue(Principal.new(id))
    end
  end
end
