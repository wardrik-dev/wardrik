defmodule WardrikMCP.ListingTest do
  use ExUnit.Case, async: true
  alias WardrikMCP.Listing

  @listed [%{"name" => "echo", "description" => "Hands the value back."}]

  setup do
    %{ref: WardrikMCP.Test.Case.fresh_ref()}
  end

  test "recalls what was remembered", %{ref: ref} do
    :ok = Listing.remember(Wardrik.Test.store(), ref, @listed)

    assert Listing.recall(Wardrik.Test.store(), ref) == @listed
  end

  test "keeps nothing where the host names no store", %{ref: ref} do
    none = WardrikStore.new(adapter: WardrikStore.None)
    log = ExUnit.CaptureLog.capture_log(fn -> :ok = Listing.remember(none, ref, @listed) end)

    assert log =~ "its tools could not be kept"
    assert Listing.recall(none, ref) == []
  end

  test "recalls nothing for a server no user has listed", %{ref: ref} do
    assert Listing.recall(Wardrik.Test.store(), ref) == []
  end

  test "does not write a listing the store already holds", %{ref: ref} do
    :ok = Listing.remember(Wardrik.Test.store(), ref, @listed)

    {_listed, vsn} =
      WardrikStore.lookup(Wardrik.Test.store(), Listing.namespace(), Atom.to_string(ref))

    :ok = Listing.remember(Wardrik.Test.store(), ref, @listed)

    assert {@listed, ^vsn} =
             WardrikStore.lookup(Wardrik.Test.store(), Listing.namespace(), Atom.to_string(ref))
  end

  test "keeps a listing that changed", %{ref: ref} do
    :ok = Listing.remember(Wardrik.Test.store(), ref, @listed)
    grown = @listed ++ [%{"name" => "grown"}]

    :ok = Listing.remember(Wardrik.Test.store(), ref, grown)

    assert Listing.recall(Wardrik.Test.store(), ref) == grown
  end
end
