defmodule WardrikDaemon.GrantsTest do
  # What config.yaml says of channels, and the agents' defaults, are the
  # node's, which these tests set.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Grant
  alias Wardrik.Principal
  alias WardrikDaemon.Agents
  alias WardrikDaemon.Grants
  alias WardrikDaemon.Test.Host

  setup %{tmp_dir: dir}, do: %{dir: dir}

  # The daemon's grants, read under the sections the test has put.
  defp grants, do: Wardrik.Host.grants(Host.host(Host.agents()))

  # The test channel knows people by their id alone.
  defp channel(settings) do
    Host.put_section(
      WardrikChannel,
      Keyword.merge([channels: [chat: {WardrikDaemon.Test.Channel, []}]], settings)
    )
  end

  defp in_chat(user),
    do: Grants.grants(grants(), WardrikChannel.principal(:chat, user, nil))

  defp can(grants), do: Enum.map(grants, &{to_string(&1.scope), &1.can})

  test "whoever holds the node may do anything to every agent" do
    for type <- [:shell, :terminal, :ssh] do
      assert [%Grant{can: can} = grant] =
               Grants.grants(grants(), Principal.new(type, "jon"))

      assert can == Grant.actions()
      assert Grant.covers?(grant, AgentID.parse!("anyone/@at/all"))
    end
  end

  test "a token holds what it grants, until it is revoked" do
    {:ok, _secret, token} =
      WardrikHTTP.Token.create(Wardrik.Test.store(), "ci",
        scope: Prefix.new!(org: "acme"),
        can: [
          :read,
          :message
        ]
      )

    principal = Principal.new(:token, token.id, name: "ci")

    assert Grants.grants(grants(), principal) == [token.grant]
    :ok = WardrikHTTP.Token.revoke(Wardrik.Test.store(), token.id)
    assert Grants.grants(grants(), principal) == []
  end

  test "a person in a channel reads and messages its orgs' agents, and decides only where named" do
    channel(orgs: [chat: ["acme", "globex"]])

    assert can(in_chat("U1")) == [
             {"acme/", [:read, :message]},
             {"globex/", [:read, :message]}
           ]

    channel(orgs: [chat: :all], approvers: [chat: %WardrikDaemon.Approvers.Named{names: ["U2"]}])
    assert can(in_chat("U1")) == [{"", [:read, :message]}]
    assert can(in_chat("U2")) == [{"", [:read, :message, :decide]}]
  end

  test "with approvers: anyone, everyone in the channel decides" do
    channel(orgs: [chat: ["acme"]], approvers: [chat: %WardrikDaemon.Approvers.Anyone{}])
    assert can(in_chat("U1")) == [{"acme/", [:read, :message, :decide]}]
  end

  test "a grant on the channel's orgs reaches none of their users' agents" do
    channel(orgs: [chat: ["acme"]])
    assert [grant] = in_chat("U1")
    assert Grant.covers?(grant, AgentID.parse!("acme/books"))
    refute Grant.covers?(grant, AgentID.parse!("acme/@bob/assistant"))
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

    assert can(in_chat("U3")) == [{"acme/", [:read, :message, :decide]}]
    assert can(in_chat("U4")) == [{"acme/", [:read, :message]}]
  end

  test "an admin defines only under the policy the defaults name", %{dir: dir} do
    channel(
      orgs: [chat: ["acme"]],
      approvers: [chat: %WardrikDaemon.Approvers.Named{names: ["U2"]}],
      admins: [chat: ["U1"]]
    )

    assert can(in_chat("U1")) == [{"acme/", [:read, :message, :decide]}]

    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join([dir, "policies", "careful.yaml"]), "deny: [run_lua]\n")
    Host.put_section(Agents, defaults: %{"policy" => "careful"})
    Host.start_agents(dir)
    _files = Agents.files(Host.agents())

    assert [%Grant{can: [:read, :message, :decide, :define], ceiling: [_ | _]}] = in_chat("U1")
  end

  test "a user's agent the channel offers is reached as the org's, but never to define",
       %{dir: dir} do
    org = "offered-#{System.unique_integer([:positive])}"

    channel(
      orgs: [chat: [org]],
      approvers: [chat: %WardrikDaemon.Approvers.Named{names: ["U2"]}],
      admins: [chat: ["U1"]]
    )

    File.mkdir_p!(Path.join(dir, "agents"))

    File.write!(
      Path.join([dir, "agents", "digest.md"]),
      "---\norg: #{org}\nuser: jon\nchannels: [chat]\n---\nDigest.\n"
    )

    File.write!(
      Path.join([dir, "agents", "notes.md"]),
      "---\norg: #{org}\nuser: ann\n---\nNotes.\n"
    )

    Host.start_agents(dir)
    _files = Agents.files(Host.agents())

    assert can(in_chat("U3")) == [
             {"#{org}/", [:read, :message]},
             {"#{org}/@jon/digest", [:read, :message]}
           ]

    assert {"#{org}/@jon/digest", [:read, :message, :decide]} in can(in_chat("U2"))
    assert {"#{org}/@jon/digest", [:read, :message, :decide]} in can(in_chat("U1"))
    refute Enum.any?(in_chat("U1"), &Grant.covers?(&1, AgentID.parse!("#{org}/@ann/notes")))
  end

  test "anyone else holds nothing" do
    for type <- [:oauth, :webhook, :agent, :user] do
      assert Grants.grants(grants(), Principal.new(type, "acme/x")) == []
    end
  end
end
