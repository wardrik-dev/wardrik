defmodule WardrikDaemon.IssuerTest do
  # What config.yaml says of channels, and the agents' defaults, are the
  # node's, which these tests set.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Principal
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
          installations: WardrikChannel.Installations.Config.new([{:chat, "token", Prefix.all()}])
        ],
        settings
      )
    )
  end

  defp in_chat(user) do
    {:ok, installation} = Agents.installation(Host.agents(), "chat")
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

  defp bound(roles), do: Wardrik.Role.bind(roles, Prefix.all()).actions

  test "whoever holds the node holds owner on every agent" do
    for type <- [:shell, :terminal, :ssh] do
      jon = Principal.new(type, "jon")
      assert %Token{principal: ^jon} = token = issue(jon)
      assert roles(token) == [{"", ["*"]}]
      assert Token.authorize(token, "agent.define", AgentID.parse!("anyone/@at/all")) == :ok
    end
  end

  test "a person in a channel reads and messages its orgs' agents, and decides only where named" do
    channel(orgs: [chat: ["acme", "globex"]])

    assert roles(in_chat("U1")) == [
             {"acme/", bound([:reader, :messenger])},
             {"globex/", bound([:reader, :messenger])}
           ]

    channel(orgs: [chat: :all], approvers: [chat: %WardrikChannel.Approvers.Named{names: ["U2"]}])
    assert roles(in_chat("U1")) == [{"", bound([:reader, :messenger])}]
    assert roles(in_chat("U2")) == [{"", bound([:reader, :messenger, :approver])}]
  end

  test "with approvers: anyone, everyone in the channel decides" do
    channel(orgs: [chat: ["acme"]], approvers: [chat: %WardrikChannel.Approvers.Anyone{}])
    assert roles(in_chat("U1")) == [{"acme/", bound([:reader, :messenger, :approver])}]
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

    assert roles(in_chat("U3")) == [{"acme/", bound([:reader, :messenger, :approver])}]
    assert roles(in_chat("U4")) == [{"acme/", bound([:reader, :messenger])}]
  end

  test "an admin defines only under the policy the defaults name", %{dir: dir} do
    channel(
      orgs: [chat: ["acme"]],
      approvers: [chat: %WardrikChannel.Approvers.Named{names: ["U2"]}],
      admins: [chat: ["U1"]]
    )

    assert %Token{policy: :none} = token = in_chat("U1")
    assert roles(token) == [{"acme/", bound([:reader, :messenger, :approver])}]

    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join([dir, "policies", "careful.yaml"]), "deny: [run_lua]\n")
    Host.put_section(Agents, defaults: %{"policy" => "careful"})
    Host.start_agents(dir)
    _files = Agents.files(Host.agents())

    assert %Token{policy: "careful"} = token = in_chat("U1")
    assert roles(token) == [{"acme/", bound([:reader, :messenger, :approver, :definer])}]
  end

  test "an agent reads and messages its owner's agents" do
    token = issue(Principal.new(:agent, "acme/front/thread-1"))
    assert roles(token) == [{"acme/", bound([:reader, :messenger])}]

    token = issue(Principal.new(:agent, "acme/@jon/assistant"))
    assert roles(token) == [{"acme/@jon/", bound([:reader, :messenger])}]
  end

  test "anyone else holds nothing" do
    for type <- [:oauth, :webhook, :token, :user] do
      assert %Token{scope: []} = issue(Principal.new(type, "acme/x"))
    end
  end
end
