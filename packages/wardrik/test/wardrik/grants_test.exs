defmodule Wardrik.GrantsTest do
  # The host's grants module is one for the node, which these tests set.
  use ExUnit.Case, async: false

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Grants
  alias Wardrik.Principal

  import Wardrik.AgentID, only: [sigil_A: 2]

  # Maria reads acme's agents and decides globex's; nobody else holds anything.
  defmodule Held do
    @moduledoc false
    @behaviour Wardrik.Grants

    @impl true
    def grants(principal) do
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

  setup do
    on_exit(fn -> Grants.configure(nil) end)
  end

  test "a principal is a caller holding the grant that reaches what they act on" do
    :ignore = Grants.configure(Held)
    maria = Principal.new(:user, "maria")

    assert {:ok, %Caller{principal: ^maria, grant: acme}} = Grants.caller(maria, ~A"acme/triage")
    assert acme.can == [:read]

    assert {:ok, %Caller{grant: globex}} = Grants.caller(maria, Prefix.new!(org: "globex"))
    assert Grant.allows?(globex, :decide, ~A"globex/triage")
  end

  test "nothing outside their grants, or for nobody, is within reach" do
    :ignore = Grants.configure(Held)

    assert {:error, %Error{type: :not_found}} =
             Grants.caller(Principal.new(:user, "maria"), ~A"initech/triage")

    assert {:error, %Error{type: :not_found}} =
             Grants.caller(Principal.new(:user, "jon"), ~A"acme/triage")

    assert {:error, %Error{type: :not_found}} = Grants.caller(nil, ~A"acme/triage")
  end

  test "a host that names no module grants nobody anything" do
    :ignore = Grants.configure(nil)

    assert {:error, %Error{type: :unsupported}} =
             Grants.caller(Principal.new(:user, "maria"), ~A"acme/triage")
  end
end
