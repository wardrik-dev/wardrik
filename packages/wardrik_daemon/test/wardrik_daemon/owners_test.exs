defmodule WardrikDaemon.OwnersTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Owners

  test "only WardrikDaemon.Owners reads an owner's org or person" do
    readers =
      for path <- Path.wildcard("lib/**/*.ex"),
          path != "lib/wardrik_daemon/owners.ex",
          File.read!(path) =~ ~r{"/@"|String\.split\((owner|id)},
          do: path

    assert readers == []
  end

  test "nothing in the daemon reads an agent's ID" do
    readers =
      for path <- Path.wildcard("lib/**/*.ex"),
          File.read!(path) =~ ~r{AgentID|String\.split\(id|Owners\.owner\(id},
          do: path

    assert readers == []
  end

  test "reads an agent's owner from its record, never its ID" do
    store = Wardrik.Store.ETS.new(name: :"owners #{System.unique_integer()}")
    start_supervised!({Wardrik.Store, store})
    store = Wardrik.Store.scope(store, "wardrik_daemon", format: Wardrik.Store.Format.Term)
    {:ok, record} = AgentRecords.create(store, owner: "acme/@jon", name: "notes", source: :api)

    assert "agt_" <> _ulid = record.id
    assert Owners.owner(store, record.id) == {:ok, "acme/@jon"}
    assert Owners.org_of(store, {:agent, record.id}) == "acme"

    for id <- ["acme/@jon/notes", "acme/triage", "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN", ""] do
      assert Owners.owner(store, id) == :error, id
      assert Owners.org_of(store, {:agent, id}) == nil, id
    end
  end
end
