defmodule WardrikDaemon.ChannelMembersTest do
  use ExUnit.Case, async: false

  import WardrikDaemon.Test

  alias Wardrik.Chat.Identities.Request
  alias Wardrik.Chat.Member
  alias Wardrik.Chat.Workspace
  alias WardrikCore.Principal
  alias WardrikDaemon.ChannelMembers

  @ana %Member{id: "U1", name: "Ana"}
  @li %Member{id: "U7", name: "Li", email: "Li@Acme.com"}
  @stranger %Member{id: "U9", name: "Stranger", email: "stranger@globex.com"}

  setup context do
    context = dirs(context)

    write(context, "config.yaml", """
    org: acme
    http: {port: #{free_port()}}
    defaults: {model: #{model()}}
    roles:
      reader: {rules: [{verbs: [read, events], kinds: [agent]}]}
    bindings:
      - {org: acme, role: reader, subjects: [user:acme/@ana, user:acme/@li]}
    channels:
      slack: {type: slack, token: xoxb-1, signing_secret: s, members: {U1: user:acme/@ana}, domains: {acme.com: acme}}
    """)

    write(context, "agents/triage.md", "Triages.\n")
    start_daemon(context)
  end

  defp workspace(context, name) do
    {:ok, {adapter, opts}} = Wardrik.Operations.Channels.fetch(context.wardrik, name)
    {:ok, workspace} = Wardrik.Chat.workspace(Wardrik.Chat.channel(adapter, opts), "T1")
    workspace
  end

  test "maps a member by ID, then by their email address's domain, and refuses anyone else" do
    members = %{"U9" => "acme/@ana"}
    domains = %{"acme.com" => "acme"}
    request = %Request{channel: "slack", workspace: "T1", member: "U9", name: "Stranger"}

    assert {:error, why} = ChannelMembers.identify(request, members: %{}, domains: domains)
    assert why =~ "channels.slack.members"

    assert {:ok, %Principal{id: "acme/@ana", attributes: %{name: "Stranger"}}} =
             ChannelMembers.identify(request, members: members, domains: domains)

    by_email = %{request | email: "ANA@acme.com"}

    assert {:ok, %Principal{id: "acme/@ana"}} =
             ChannelMembers.identify(by_email, members: %{}, domains: domains)

    for email <- ["ana@globex.com", "ana@sub.acme.com", "a:b@acme.com", "not-an-address"] do
      assert {:error, _why} =
               ChannelMembers.identify(%{request | email: email}, members: %{}, domains: domains)
    end
  end

  test "a mapped member acts as their user, so that user's bindings decide", context do
    slack = workspace(context, "slack")

    for member <- [@ana, @li] do
      assert {:ok, %Wardrik.Scope{} = scope} = Workspace.member_scope(slack, member)
      assert {:ok, %Wardrik.Agent{}} = Wardrik.Agent.read(scope, id(context, "acme", "triage"))

      assert {:error, %Wardrik.Error{type: :forbidden}} =
               Wardrik.Agent.ask(scope, id(context, "acme", "triage"), content: "Hi")
    end

    assert {:ok, %Wardrik.Scope{principal: %Principal{id: "acme/@li"}}} =
             Workspace.member_scope(slack, @li)

    assert {:error, why} = Workspace.member_scope(slack, @stranger)
    assert why =~ "Ask an admin"
    assert Wardrik.Chat.Workspace.offered(slack, @stranger) == []
  end
end
