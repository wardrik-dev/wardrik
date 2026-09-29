# What dev/hosts.sh runs inside each application it makes, as
# `mix run check.exs`, so it runs against the application as it runs: the
# store it keeps Wardrik in passes Wardrik.Store.Conformance, an agent spawned
# in its fleet is kept there, and what it leaves out of its dependencies is
# not loaded.
#
#   WARDRIK_HOST_STORE     the adapter the application configured
#   WARDRIK_HOST_WITHOUT   modules it must not have, separated by commas
#   WARDRIK_HOST_REPO      the application's repo, where the store is kept in it

ExUnit.start(autorun: false)

defmodule WardrikHost.StoreTest do
  use ExUnit.Case, async: false
  use Wardrik.Store.Conformance, adapter: Wardrik.Store.adapter()
end

defmodule WardrikHost.FleetTest do
  use ExUnit.Case, async: false

  test "the store is the one the application configured" do
    assert inspect(Wardrik.Store.adapter()) == System.fetch_env!("WARDRIK_HOST_STORE")
  end

  test "what the application does not depend on is not loaded" do
    for name <- String.split(System.get_env("WARDRIK_HOST_WITHOUT", ""), ",", trim: true) do
      refute Code.ensure_loaded?(Module.concat([name])), "#{name} is loaded"
    end
  end

  test "an agent spawned in the fleet is kept in the application's store" do
    name = "host-#{System.unique_integer([:positive])}"
    key = Wardrik.Fleet.key(name)

    assert {:ok, _pid} = Wardrik.Fleet.spawn(key)
    assert key in Enum.map(Wardrik.Fleet.list(), & &1.key)
    assert Enum.any?(Wardrik.Store.keys(:durable, Wardrik.Fleet.prefix()), &(&1 =~ name))

    if repo = System.get_env("WARDRIK_HOST_REPO") do
      %{rows: rows} =
        Module.concat([repo]).query!("SELECT key FROM wardrik_records WHERE key LIKE $1", [
          "%#{name}%"
        ])

      assert rows != [], "nothing of #{name} is in #{repo}'s wardrik_records"
    end
  end
end

%{failures: failures} = ExUnit.run()
System.halt(if failures == 0, do: 0, else: 1)
