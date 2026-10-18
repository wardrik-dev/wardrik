defmodule WardrikOAuth.ConnectionsTest do
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Principal
  alias Wardrik.Session
  alias Wardrik.Test.Audit

  setup %{owner: owner} do
    start_supervised!({WardrikOAuth.Supervisor, oauth: oauth(), callback: false})

    stub_server(cimd: true)

    configure(
      providers: [
        github: [resource: resource(), scopes: ~w(repo)],
        linear: [resource: resource(), scopes: ~w(read)]
      ]
    )

    org = "acme#{owner}"
    {:ok, grant} = Grant.new(Prefix.tenant!(org))

    jon =
      Session.new(host: host(), principal: Principal.new(:user, owner, name: "Jon"), grant: grant)

    %{org: org, jon: jon, mine: Prefix.new!(org: org, user: owner)}
  end

  defp list(session, mine) do
    {:ok, connections} = Wardrik.connections_list(session, mine)
    Map.new(connections, &{&1.provider, &1.held_by})
  end

  defp authorize(session, mine, provider) do
    {:ok, %{authorization: %{url: url}}} = Wardrik.connections_connect(session, mine, provider)
    {:ok, ^provider} = WardrikOAuth.finish(state_of(url), "the-code")
  end

  test "lists what the person holds, and what they do not", %{jon: jon, mine: mine} do
    authorize(jon, mine, "github")

    assert list(jon, mine) == %{"github" => :person, "linear" => nil}
  end

  test "connecting answers a link, and once the browser is back the account is held",
       %{jon: jon, mine: mine, org: org, owner: owner} do
    assert {:ok, %{authorization: %{url: url}}} = Wardrik.connections_connect(jon, mine, "linear")

    assert list(jon, mine)["linear"] == nil
    assert {:ok, "linear"} = WardrikOAuth.finish(state_of(url), "the-code")

    assert list(jon, mine)["linear"] == :person
    assert {:ok, %{authorization: nil}} = Wardrik.connections_connect(jon, mine, "linear")

    assert [{"secret.stored", %{"type" => "user", "id" => ^owner}} | _] =
             Enum.reverse(Audit.about("secrets/linear"))

    refute WardrikOAuth.connected?(vault(), "linear", org)
  end

  test "disconnecting removes it, recorded as the person who did",
       %{jon: jon, mine: mine, owner: owner} do
    authorize(jon, mine, "linear")

    assert {:ok, %Wardrik.Connections.Connection{provider: "linear", held_by: :person}} =
             Wardrik.connections_disconnect(jon, mine, "linear")

    assert list(jon, mine)["linear"] == nil

    assert {"secret.removed", %{"type" => "user", "id" => ^owner}} =
             List.last(Audit.about("secrets/linear"))

    assert {:error, %Error{type: :not_found}} =
             Wardrik.connections_disconnect(jon, mine, "linear")
  end

  test "a token for one org can neither see nor touch another's",
       %{jon: jon, mine: mine, owner: owner} do
    authorize(jon, mine, "github")
    globex = Prefix.new!(org: "globex#{owner}", user: owner)

    assert {:error, %Error{type: :not_found}} = Wardrik.connections_list(jon, globex)

    assert {:error, %Error{type: :not_found}} =
             Wardrik.connections_disconnect(jon, globex, "github")

    assert {:error, %Error{type: :not_found}} = Wardrik.connections_connect(jon, globex, "github")
    assert list(jon, mine)["github"] == :person
  end

  test "an org's account shows as the org's to its people", %{jon: jon, mine: mine, org: org} do
    {:ok, %{authorization: %{url: url}}} =
      Wardrik.connections_connect(jon, Prefix.new!(org: org), "linear")

    {:ok, "linear"} = WardrikOAuth.finish(state_of(url), "the-code")

    assert list(jon, mine)["linear"] == :org
    assert WardrikOAuth.connected?(vault(), "linear", org)
  end
end
