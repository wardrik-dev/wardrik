defmodule WardrikMCP.ListingTest do
  use ExUnit.Case, async: true
  alias WardrikMCP.Listing

  @listed [%{"name" => "echo", "description" => "Hands the value back."}]

  setup do
    %{key: WardrikMCP.Test.Case.fresh_key()}
  end

  test "recalls what was remembered", %{key: key} do
    :ok = Listing.remember(Wardrik.Test.store(), key, @listed)

    assert Listing.recall(Wardrik.Test.store(), key) == @listed
  end

  test "keeps nothing where the host names no store", %{key: key} do
    none = WardrikStore.new(adapter: WardrikStore.None)
    log = ExUnit.CaptureLog.capture_log(fn -> :ok = Listing.remember(none, key, @listed) end)

    assert log =~ "its tools could not be kept"
    assert Listing.recall(none, key) == []
  end

  test "recalls nothing for a server no user has listed", %{key: key} do
    assert Listing.recall(Wardrik.Test.store(), key) == []
  end

  test "does not write a listing the store already holds", %{key: key} do
    :ok = Listing.remember(Wardrik.Test.store(), key, @listed)

    {_listed, vsn} =
      WardrikStore.lookup(Wardrik.Test.store(), Listing.namespace(), to_string(key))

    :ok = Listing.remember(Wardrik.Test.store(), key, @listed)

    assert {@listed, ^vsn} =
             WardrikStore.lookup(Wardrik.Test.store(), Listing.namespace(), to_string(key))
  end

  test "keeps a listing that changed", %{key: key} do
    :ok = Listing.remember(Wardrik.Test.store(), key, @listed)
    grown = @listed ++ [%{"name" => "grown"}]

    :ok = Listing.remember(Wardrik.Test.store(), key, grown)

    assert Listing.recall(Wardrik.Test.store(), key) == grown
  end
end
