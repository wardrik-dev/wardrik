defmodule Wardrik.Connections.OwnerTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Connections.Owner

  test "is the owner whose agents are under a prefix, and back" do
    assert Owner.owner_of(Prefix.parse!("acme/@jon/")) == {"acme", "jon"}
    assert Owner.owner_of(Prefix.parse!("acme/")) == "acme"
    assert Owner.prefix({"acme", "jon"}) == Prefix.parse!("acme/@jon/")
    assert Owner.prefix(nil) == Prefix.all()
  end
end
