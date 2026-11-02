defmodule WardrikDaemon.ChannelMembersTest do
  use ExUnit.Case, async: false

  import WardrikDaemon.Test

  alias WardrikChannel.Identities.Request
  alias WardrikChannel.Member
  alias WardrikChannel.Workspace
  alias WardrikCore.Principal
  alias WardrikDaemon.ChannelMembers

  @ana %Member{id: "U1", name: "Ana"}
  @stranger %Member{id: "U9", name: "Stranger"}

  setup context do
    context = dirs(context)

    write(context, "config.yaml", """
    org: acme
    http: {port: #{free_port()}}
    defaults: {model: #{model()}}
    roles:
      reader: {rules: [{verbs: [read, events], kinds: [agent]}]}
    bindings:
      - {org: acme, role: reader, subjects: [user:acme/@ana, "user:open:T1/U9"]}
    channels:
      slack: {type: slack, token: xoxb-1, signing_secret: s, members: {U1: user:acme/@ana}}
      open: {type: slack, token: xoxb-2, signing_secret: s, unmapped_members: allow}
    """)

    write(context, "agents/triage.md", "Triages.\n")
    start_daemon(context)
  end

  defp workspace(context, name) do
    {:ok, {adapter, opts}} = Wardrik.Operations.Channels.fetch(context.wardrik, name)
    {:ok, workspace} = WardrikChannel.workspace(WardrikChannel.channel(adapter, opts), "T1")
    workspace
  end

  test "refuses a member config.yaml doesn't map, unless unmapped members are allowed" do
    request = %Request{channel: "slack", workspace: "T1", member: "U9", name: "Stranger"}

    assert {:error, why} = ChannelMembers.identify(request, members: %{}, unmapped: :refuse)
    assert why =~ "channels.slack.members"

    assert {:ok, %Principal{id: "slack:T1/U9"}} =
             ChannelMembers.identify(request, members: %{}, unmapped: :allow)

    assert {:ok, %Principal{id: "acme/@ana", attributes: %{name: "Stranger"}}} =
             ChannelMembers.identify(request, members: %{"U9" => "acme/@ana"}, unmapped: :refuse)
  end

  test "a mapped member acts as their user, so that user's bindings decide", context do
    slack = workspace(context, "slack")

    assert {:ok, %Wardrik.Scope{principal: %Principal{id: "acme/@ana"}} = scope} =
             Workspace.member_scope(slack, @ana)

    assert {:ok, %Wardrik.Agent{}} = Wardrik.Agent.read(scope, id(context, "acme", "triage"))

    assert {:error, %Wardrik.Error{type: :forbidden}} =
             Wardrik.Agent.ask(scope, id(context, "acme", "triage"), content: "Hi")

    assert {:error, why} = Workspace.member_scope(slack, @stranger)
    assert why =~ "Ask an admin"
    assert WardrikChannel.Workspace.offered(slack, @stranger) == []
  end

  test "an unmapped member, where allowed, acts as a user of their own", context do
    open = workspace(context, "open")

    assert {:ok, %Wardrik.Scope{principal: %Principal{id: "open:T1/U9"}} = scope} =
             Workspace.member_scope(open, @stranger)

    assert {:ok, %Wardrik.Agent{}} = Wardrik.Agent.read(scope, id(context, "acme", "triage"))

    {:ok, other} = Workspace.member_scope(open, %Member{id: "U8"})

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.Agent.read(other, id(context, "acme", "triage"))
  end
end
