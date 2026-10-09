defmodule WardrikMCP.ListingTest do
  use ExUnit.Case, async: true
  alias WardrikMCP.Listing

  @listed [%{"name" => "echo", "description" => "Hands the value back."}]

  setup do
    %{ref: WardrikMCP.Test.Case.fresh_ref()}
  end

  test "recalls what was remembered", %{ref: ref} do
    :ok = Listing.remember(ref, @listed)

    assert Listing.recall(ref) == @listed
  end

  test "recalls nothing for a server no user has listed", %{ref: ref} do
    assert Listing.recall(ref) == []
  end

  test "does not write a listing the store already holds", %{ref: ref} do
    :ok = Listing.remember(ref, @listed)
    {_listed, vsn} = WardrikStore.lookup(Listing.namespace(), Atom.to_string(ref))

    :ok = Listing.remember(ref, @listed)

    assert {@listed, ^vsn} = WardrikStore.lookup(Listing.namespace(), Atom.to_string(ref))
  end

  test "keeps a listing that changed", %{ref: ref} do
    :ok = Listing.remember(ref, @listed)
    grown = @listed ++ [%{"name" => "grown"}]

    :ok = Listing.remember(ref, grown)

    assert Listing.recall(ref) == grown
  end
end
