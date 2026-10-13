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

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:wardrik_daemon, Agents)

    on_exit(fn ->
      Application.delete_env(:wardrik_daemon, WardrikChannel)
      Application.delete_env(:wardrik_daemon, WardrikNotify)
      Application.put_env(:wardrik_daemon, Agents, previous || [])
    end)

    %{dir: dir}
  end

  # The test channel knows people by their id alone.
  defp channel(settings) do
    Application.put_env(
      :wardrik_daemon,
      WardrikChannel,
      Keyword.merge([channels: [chat: {WardrikDaemon.Test.Channel, []}]], settings)
    )
  end

  defp in_chat(user),
    do: Grants.grants(Wardrik.Test.host(), WardrikChannel.principal(:chat, user, nil))

  defp can(grants), do: Enum.map(grants, &{to_string(&1.scope), &1.can})

  test "whoever holds the node may do anything to every agent" do
    for type <- [:shell, :terminal, :ssh] do
      assert [%Grant{can: can} = grant] =
               Grants.grants(Wardrik.Test.host(), Principal.new(type, "jon"))

      assert can == Grant.actions()
      assert Grant.covers?(grant, AgentID.parse!("anyone/@at/all"))
    end
  end

  test "a token holds what it grants, until it is revoked" do
    {:ok, _secret, token} =
      WardrikHTTP.Token.create(Wardrik.Test.store(), "ci", Prefix.new!(org: "acme"), [
        :read,
        :message
      ])

    principal = Principal.new(:token, token.id, name: "ci")

    assert Grants.grants(Wardrik.Test.host(), principal) == [token.grant]
    :ok = WardrikHTTP.Token.revoke(Wardrik.Test.store(), token.id)
    assert Grants.grants(Wardrik.Test.host(), principal) == []
  end

  test "a person in a channel reads and messages its orgs' agents, and decides where nobody is named" do
    channel(orgs: [chat: ["acme", "globex"]])

    assert can(in_chat("U1")) == [
             {"acme/", [:read, :message, :decide]},
             {"globex/", [:read, :message, :decide]}
           ]

    channel(orgs: [chat: :all], approvers: [chat: ["U2"]])
    assert can(in_chat("U1")) == [{"", [:read, :message]}]
    assert can(in_chat("U2")) == [{"", [:read, :message, :decide]}]
  end

  test "the approvers of a notify target posting in the channel decide there" do
    channel(orgs: [chat: ["acme"]])

    Application.put_env(:wardrik_daemon, WardrikNotify,
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
    channel(orgs: [chat: ["acme"]], approvers: [chat: ["U2"]], admins: [chat: ["U1"]])
    assert can(in_chat("U1")) == [{"acme/", [:read, :message, :decide]}]

    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join([dir, "policies", "careful.yaml"]), "deny: [run_lua]\n")
    Application.put_env(:wardrik_daemon, Agents, defaults: %{"policy" => "careful"})
    start_supervised!({Agents, dir: dir, store: Wardrik.Test.store()})
    _files = Agents.files()

    assert [%Grant{can: [:read, :message, :decide, :define], ceiling: [_ | _]}] = in_chat("U1")
  end

  test "anyone else holds nothing" do
    for type <- [:oauth, :webhook, :agent, :user] do
      assert Grants.grants(Wardrik.Test.host(), Principal.new(type, "acme/x")) == []
    end
  end
end
