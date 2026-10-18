defmodule Wardrik.Connections.OwnerTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Connections.Owner
  alias Wardrik.Error
  alias Wardrik.Grant
  alias Wardrik.Principal

  @jon Principal.new(:user, "jon")

  defp caller(scope, principal \\ @jon) do
    {:ok, grant} = Grant.new(Prefix.parse!(scope))
    Caller.new(principal: principal, grant: grant, host: Wardrik.Host.new())
  end

  defp owner(caller, whose) do
    with {:ok, prefix} <- Owner.owner(caller, whose), do: {:ok, to_string(prefix)}
  end

  test "is the person a scope names, else the person the caller acts as" do
    assert owner(caller("acme/@jon/", nil), :person) == {:ok, "acme/@jon/"}
    assert owner(caller("acme/*"), :person) == {:ok, "acme/@jon/"}
    assert owner(caller("acme/"), :org) == {:ok, "acme/"}
  end

  test "needs a person, or the org, and one org" do
    assert {:error, %Error{type: :invalid, message: message}} =
             owner(caller("acme/", Principal.new(:token, "t1")), :person)

    assert message =~ "owner=org"
    assert owner(caller("acme/", Principal.new(:token, "t1")), :org) == {:ok, "acme/"}
    assert {:error, %Error{type: :invalid}} = owner(caller(""), :person)
  end

  test "is the owner whose agents are under a prefix, and back" do
    assert Owner.owner_of(Prefix.parse!("acme/@jon/")) == {"acme", "jon"}
    assert Owner.owner_of(Prefix.parse!("acme/")) == "acme"
    assert Owner.prefix({"acme", "jon"}) == Prefix.parse!("acme/@jon/")
    assert Owner.prefix(nil) == Prefix.all()
  end
end
