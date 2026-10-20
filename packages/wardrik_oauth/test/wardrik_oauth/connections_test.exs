defmodule WardrikOAuth.ConnectionsTest do
  use WardrikOAuth.Test.Case, async: false

  alias Wardrik.Error
  alias Wardrik.Principal
  alias Wardrik.Role
  alias Wardrik.Scope
  alias Wardrik.Test.Audit
  alias Wardrik.Token

  setup %{owner: owner} do
    start_supervised!(WardrikOAuth.Supervisor)

    stub_server(cimd: true)

    configure(
      providers: [
        github: [resource: resource(), scopes: ~w(repo)],
        linear: [resource: resource(), scopes: ~w(read)]
      ]
    )

    org = "acme#{owner}"

    jon =
      Scope.new(host(), %Token{
        principal: Principal.new("#{org}/@#{owner}", name: "Jon"),
        scope: [Role.bind([:owner], [Wardrik.Resource.parse!("#{org}/*")])]
      })

    %{org: org, jon: jon, mine: person(org, owner)}
  end

  defp list(scope, mine) do
    {:ok, connections} = Wardrik.connections_list(scope, mine)
    Map.new(connections, &{&1.provider, &1.connected})
  end

  defp authorize(scope, mine, provider) do
    {:ok, %{authorization: %{url: url}}} = Wardrik.connections_connect(scope, mine, provider)
    {:ok, ^provider} = WardrikOAuth.finish(state_of(url), "the-code")
  end

  test "lists what the person holds, and what they do not", %{jon: jon, mine: mine} do
    authorize(jon, mine, "github")

    assert list(jon, mine) == %{"github" => true, "linear" => false}
  end

  test "connecting answers a link, and once the browser is back the account is held",
       %{jon: jon, mine: mine, org: org} do
    assert {:ok, %{authorization: %{url: url}}} = Wardrik.connections_connect(jon, mine, "linear")

    assert list(jon, mine)["linear"] == false
    assert {:ok, "linear"} = WardrikOAuth.finish(state_of(url), "the-code")

    assert list(jon, mine)["linear"] == true
    assert {:ok, %{authorization: nil}} = Wardrik.connections_connect(jon, mine, "linear")

    jon_id = to_string(mine)

    assert [{"secret.stored", %{"id" => ^jon_id}} | _] =
             Enum.reverse(Audit.about("#{mine}/secret/linear"))

    refute WardrikOAuth.connected?(vault(), "linear", Wardrik.Resource.parse!(org))
  end

  test "disconnecting removes it, recorded as the person who did",
       %{jon: jon, mine: mine} do
    authorize(jon, mine, "linear")

    assert {:ok, %Wardrik.Connections.Connection{provider: "linear", connected: true}} =
             Wardrik.connections_disconnect(jon, mine, "linear")

    assert list(jon, mine)["linear"] == false

    jon_id = to_string(mine)

    assert {"secret.removed", %{"id" => ^jon_id}} =
             List.last(Audit.about("#{mine}/secret/linear"))

    assert {:error, %Error{type: :not_found}} =
             Wardrik.connections_disconnect(jon, mine, "linear")
  end

  test "a token for one org can neither see nor touch another's",
       %{jon: jon, mine: mine, owner: owner} do
    authorize(jon, mine, "github")
    globex = person("globex#{owner}", owner)

    assert {:error, %Error{type: :not_found}} = Wardrik.connections_list(jon, globex)

    assert {:error, %Error{type: :not_found}} =
             Wardrik.connections_disconnect(jon, globex, "github")

    assert {:error, %Error{type: :not_found}} = Wardrik.connections_connect(jon, globex, "github")
    assert list(jon, mine)["github"] == true
  end

  test "an org's account is the org's own, and none of its people's",
       %{jon: jon, mine: mine, org: org} do
    org = Wardrik.Resource.parse!(org)
    {:ok, %{authorization: %{url: url}}} = Wardrik.connections_connect(jon, org, "linear")
    {:ok, "linear"} = WardrikOAuth.finish(state_of(url), "the-code")

    assert list(jon, org)["linear"] == true
    assert list(jon, mine)["linear"] == false
  end
end
