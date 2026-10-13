defmodule WardrikOAuth.ConnectionsTest do
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Command
  alias Wardrik.Connections
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Operations.Connect
  alias Wardrik.Operations.Disconnect
  alias Wardrik.Operations.ReadConnections
  alias Wardrik.Principal
  alias Wardrik.Query
  alias Wardrik.Test.Audit

  setup %{owner: owner} do
    start_supervised!({WardrikOAuth.Supervisor, callback: false})

    stub_server(cimd: true)

    configure(
      providers: [
        github: [resource: resource(), scopes: ~w(repo)],
        linear: [resource: resource(), scopes: ~w(read)]
      ]
    )

    org = "acme#{owner}"
    %{org: org, jon: caller(org, owner)}
  end

  defp caller(org, user) do
    {:ok, grant} = Grant.new(Prefix.new!(org: org))

    Caller.new(
      principal: Principal.new(:user, user, name: "Jon"),
      grant: grant,
      host: Wardrik.Host.new(store: Wardrik.Test.store(), connections: WardrikOAuth.Connections)
    )
  end

  defp list(caller) do
    {:ok, request} = Connections.request(ReadConnections, caller, :person)
    {:ok, %{"connections" => connections}} = Query.run(request, caller)
    Map.new(connections, &{&1["provider"], &1["held_by"]})
  end

  defp connect(caller, provider) do
    {:ok, request} = Connections.request(Connect, caller, :person, provider: provider)
    Command.run(request, caller)
  end

  defp authorize(caller, provider) do
    {:ok, %{"authorization" => %{"url" => url}}} = connect(caller, provider)
    {:ok, ^provider} = WardrikOAuth.finish(state_of(url), "the-code")
  end

  test "lists what the person holds, and what they do not", %{jon: jon} do
    authorize(jon, "github")

    assert list(jon) == %{"github" => "person", "linear" => nil}
  end

  test "connecting answers a link, and once the browser is back the account is held",
       %{jon: jon, org: org, owner: owner} do
    assert {:ok, %{"connected" => false, "authorization" => %{"url" => url}}} =
             connect(jon, "linear")

    assert list(jon)["linear"] == nil
    assert {:ok, "linear"} = WardrikOAuth.finish(state_of(url), "the-code")

    assert list(jon)["linear"] == "person"
    assert {:ok, %{"connected" => true}} = connect(jon, "linear")

    assert [{"secret.stored", %{"type" => "user", "id" => ^owner}} | _] =
             Enum.reverse(Audit.about("secrets/linear"))

    refute WardrikOAuth.connected?(Wardrik.Test.store(), "linear", org)
  end

  test "disconnecting removes it, recorded as the person who did", %{jon: jon, owner: owner} do
    authorize(jon, "linear")
    {:ok, request} = Connections.request(Disconnect, jon, :person, provider: "linear")

    assert {:ok, nil} = Command.run(request, jon)
    assert list(jon)["linear"] == nil

    assert {"secret.removed", %{"type" => "user", "id" => ^owner}} =
             List.last(Audit.about("secrets/linear"))

    assert {:error, %Error{type: :not_found}} = Command.run(request, jon)
  end

  test "a token for one org can neither see nor touch another's", %{jon: jon, owner: owner} do
    authorize(jon, "github")
    globex = Prefix.new!(org: "globex#{owner}", user: owner)

    assert {:error, %Error{type: :not_found}} =
             Query.run(%ReadConnections{owner: globex}, jon)

    assert {:error, %Error{type: :not_found}} =
             Command.run(%Disconnect{owner: globex, provider: "github"}, jon)

    assert {:error, %Error{type: :not_found}} =
             Command.run(%Connect{owner: globex, provider: "github"}, jon)

    assert list(jon)["github"] == "person"
  end

  test "an org's account shows as the org's to its people", %{jon: jon, org: org} do
    {:ok, request} = Connections.request(Connect, jon, :org, provider: "linear")
    {:ok, %{"authorization" => %{"url" => url}}} = Command.run(request, jon)
    {:ok, "linear"} = WardrikOAuth.finish(state_of(url), "the-code")

    assert list(jon)["linear"] == "org"
    assert WardrikOAuth.connected?(Wardrik.Test.store(), "linear", org)
  end
end
