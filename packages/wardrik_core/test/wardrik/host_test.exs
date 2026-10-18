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
    defstruct []

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

  defimpl Wardrik.Grants, for: Held do
    defdelegate grants(a0, a1), to: Held
  end

  defp host, do: Host.new(grants: %Held{})

  test "offers each seam it names, and the None of each it leaves out" do
    host = Host.new(grants: %Held{}, tokens: %Wardrik.Tokens.None{})

    assert Host.grants(host) == %Held{}
    assert Host.definitions(host) == %Wardrik.Definition.None{}
    assert Host.connections(host) == %Wardrik.Connections.None{}
    assert Host.credentials(host) == %Wardrik.Credentials.None{}
    assert Host.tokens(host) == %Wardrik.Tokens.None{}
    assert Host.triggers(host) == %Wardrik.Triggers.None{}
    assert Host.store(host) == WardrikStore.new(adapter: WardrikStore.None)
    assert_raise ArgumentError, fn -> Host.new(ledger: %Held{}) end
  end

  test "each None answers that the host offers nothing" do
    id = ~A"acme/triage"
    host = Host.new()
    connections = Host.connections(host)
    tokens = Host.tokens(host)
    definitions = Host.definitions(host)

    assert Wardrik.Connections.list(connections, "acme") == :unsupported
    assert Wardrik.Connections.connect(connections, "github", "acme", nil) == :unsupported
    assert Wardrik.Connections.disconnect(connections, "github", "acme") == :unsupported
    assert Wardrik.Tokens.create(tokens, "t", grant: nil, for: nil) == :unsupported
    assert Wardrik.Tokens.list(tokens) == :unsupported
    assert Wardrik.Tokens.revoke(tokens, "t1") == :unsupported

    assert Wardrik.Triggers.deliver(Host.triggers(host), id, "issues", %{headers: [], body: ""}) ==
             :unsupported

    assert Wardrik.Grants.grants(Host.grants(host), Principal.new(:user, "maria")) == []
    assert Wardrik.Credentials.key(Host.credentials(host), "ANTHROPIC_API_KEY") == :error

    assert Wardrik.Credentials.resolve(Host.credentials(host), "github", nil) ==
             {:error, :no_resolver}

    assert Wardrik.Credentials.refused(Host.credentials(host), "github", nil) == :ok
    assert Wardrik.Definition.current(definitions, id) == :none
    assert Wardrik.Definition.editable(definitions, id) == :ok
    assert Wardrik.Definition.delete(definitions, id) == {:error, :not_found}
    assert Wardrik.Definition.create(definitions, id) == :unsupported
    assert Wardrik.Definition.reloading(definitions) == []
    assert Wardrik.Definition.reload(definitions, host: host) == :ok
  end

  test "a principal is a caller holding the grant that reaches what they act on" do
    maria = Principal.new(:user, "maria")
    host = host()

    assert {:ok, %Caller{principal: ^maria, grant: acme, host: ^host}} =
             Host.caller(host(), principal: maria, subject: ~A"acme/triage")

    assert acme.can == [:read]

    assert {:ok, %Caller{grant: globex}} =
             Host.caller(host(), principal: maria, subject: Prefix.new!(org: "globex"))

    assert Grant.allows?(globex, :decide, ~A"globex/triage")
  end

  test "nothing outside their grants, or for nobody, is within reach" do
    maria = Principal.new(:user, "maria")

    assert {:error, %Error{type: :not_found}} =
             Host.caller(host(), principal: maria, subject: ~A"initech/triage")

    assert {:error, %Error{type: :not_found}} =
             Host.caller(host(), principal: Principal.new(:user, "jon"), subject: ~A"acme/triage")

    assert {:error, %Error{type: :not_found}} =
             Host.caller(host(), principal: nil, subject: ~A"acme/triage")
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

    host = host()

    assert %Caller{principal: ^jon, host: ^host, grant: grant} =
             Caller.root(principal: jon, host: host)

    assert grant.scope == Prefix.all()
  end
end
