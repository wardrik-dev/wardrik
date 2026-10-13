defmodule Wardrik.HostTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.Principal

  import Wardrik.AgentID, only: [sigil_A: 2]

  # Maria reads acme's agents and decides globex's; nobody else holds anything.
  defmodule Held do
    @moduledoc false
    @behaviour Wardrik.Grants

    @impl true
    def grants(_host, principal) do
      case Principal.id(principal) do
        "maria" ->
          [grant([org: "acme"], [:read]), grant([org: "globex"], [:read, :decide])]

        _anyone ->
          []
      end
    end

    defp grant(scope, can) do
      {:ok, grant} = Grant.new(Prefix.new!(scope), can)
      grant
    end
  end

  @host Host.new(grants: Held)

  test "offers each seam it names, and the None module of each it leaves out" do
    host = Host.new(grants: Held, tokens: Wardrik.Tokens.None)

    assert Host.grants(host) == Held
    assert Host.definitions(host) == Wardrik.Definition.None
    assert Host.connections(host) == Wardrik.Connections.None
    assert Host.tokens(host) == Wardrik.Tokens.None
    assert Host.triggers(host) == Wardrik.Triggers.None
    assert Host.store(host) == WardrikStore.new(adapter: WardrikStore.None)
    assert_raise ArgumentError, fn -> Host.new(ledger: Held) end
  end

  test "each None module answers that the host offers nothing" do
    id = ~A"acme/triage"
    host = Host.new()

    assert Wardrik.Connections.None.list(host, "acme") == :unsupported
    assert Wardrik.Connections.None.connect(host, "github", "acme", nil) == :unsupported
    assert Wardrik.Connections.None.disconnect(host, "github", "acme") == :unsupported
    assert Wardrik.Tokens.None.create(host, "t", nil, nil) == :unsupported
    assert Wardrik.Tokens.None.list(host) == :unsupported
    assert Wardrik.Tokens.None.revoke(host, "t1") == :unsupported
    assert Wardrik.Triggers.None.deliver(id, "issues", %{headers: [], body: ""}) == :unsupported
    assert Wardrik.Grants.None.grants(host, Principal.new(:user, "maria")) == []
    assert Wardrik.Definition.None.current(host, id) == :none
    assert Wardrik.Definition.None.editable(host, id) == :ok
    assert Wardrik.Definition.None.delete(host, id) == {:error, :not_found}
    assert Wardrik.Definition.None.create(host, id) == :unsupported
    assert Wardrik.Definition.None.reloading() == []
    assert Wardrik.Definition.None.reload() == :ok
  end

  test "a principal is a caller holding the grant that reaches what they act on" do
    maria = Principal.new(:user, "maria")

    assert {:ok, %Caller{principal: ^maria, grant: acme, host: @host}} =
             Host.caller(@host, principal: maria, subject: ~A"acme/triage")

    assert acme.can == [:read]

    assert {:ok, %Caller{grant: globex}} =
             Host.caller(@host, principal: maria, subject: Prefix.new!(org: "globex"))

    assert Grant.allows?(globex, :decide, ~A"globex/triage")
  end

  test "nothing outside their grants, or for nobody, is within reach" do
    maria = Principal.new(:user, "maria")

    assert {:error, %Error{type: :not_found}} =
             Host.caller(@host, principal: maria, subject: ~A"initech/triage")

    assert {:error, %Error{type: :not_found}} =
             Host.caller(@host, principal: Principal.new(:user, "jon"), subject: ~A"acme/triage")

    assert {:error, %Error{type: :not_found}} =
             Host.caller(@host, principal: nil, subject: ~A"acme/triage")
  end

  test "a host that names no grants module grants nobody anything" do
    assert {:error, %Error{type: :not_found}} =
             Host.caller(Host.new(),
               principal: Principal.new(:user, "maria"),
               subject: ~A"acme/triage"
             )
  end

  test "a root caller holds the node, on the host" do
    jon = Principal.new(:terminal, "jon")

    assert %Caller{principal: ^jon, host: @host, grant: grant} = Host.root(@host, principal: jon)
    assert grant.scope == Prefix.all()
  end
end
