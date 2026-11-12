defmodule WardrikDaemon.AgentRecordsTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.ULID

  setup context do
    store = WardrikStore.ETS.new(name: :"records #{context.test}")
    start_supervised!({WardrikStore, store})
    %{store: store}
  end

  test "mints ULIDs in the order they're made, as Crockford's base32" do
    made = for _each <- 1..200, do: ULID.generate()

    assert made == Enum.sort(made)
    assert Enum.uniq(made) == made
    assert Enum.all?(made, &Regex.match?(~r/\A[0-9A-HJKMNP-TV-Z]{26}\z/, &1))

    assert ULID.encode({0, 0}) == String.duplicate("0", 26)
    assert ULID.encode({1_469_918_176_385, 0}) == "01ARYZ6S41" <> String.duplicate("0", 16)

    max = Bitwise.bsl(1, 80) - 1
    assert ULID.next({5, 7}, 9, 3) == {9, 3}
    assert ULID.next({5, 7}, 5, 3) == {5, 8}
    assert ULID.next({5, 7}, 4, 3) == {5, 8}
    assert ULID.next({5, max}, 5, 3) == {6, 3}
  end

  test "keeps a name unique in its org, and reads owners from the record", %{store: store} do
    assert {:ok, notes} =
             AgentRecords.create(store, owner: "acme/@jon", name: "notes", source: :api)

    assert %{org: "acme", owner: "acme/@jon", name: "notes", id: "agt_" <> _ulid} = notes

    assert {:error, {:taken, ^notes}} =
             AgentRecords.create(store, owner: "acme", name: "notes", source: :api)

    assert {:ok, other} = AgentRecords.create(store, owner: "globex", name: "notes", source: :api)
    assert other.id != notes.id

    assert AgentRecords.fetch(store, notes.id) == {:ok, notes}
    assert AgentRecords.named(store, "acme", "notes") == {:ok, notes}
    assert AgentRecords.named(store, "globex", "notes") == {:ok, other}
    assert AgentRecords.named(store, "initech", "notes") == :error
    assert AgentRecords.in_org(store, "acme") == [notes]

    assert {:ok, again} =
             AgentRecords.create(store,
               owner: "acme",
               name: "notes",
               source: :api,
               replaces: &(&1 == notes)
             )

    assert again.id != notes.id
    assert AgentRecords.fetch(store, notes.id) == :error
    assert AgentRecords.named(store, "acme", "notes") == {:ok, again}

    assert :ok = AgentRecords.delete(store, notes)
    assert AgentRecords.named(store, "acme", "notes") == {:ok, again}
    assert :ok = AgentRecords.delete(store, again)
    assert AgentRecords.named(store, "acme", "notes") == :error
  end

  test "keeps no record for a name it couldn't claim", %{store: store} do
    {:ok, notes} = AgentRecords.create(store, owner: "acme", name: "notes", source: :file)

    assert {:error, {:taken, ^notes}} =
             AgentRecords.create(store, owner: "acme", name: "notes", source: :file)

    assert AgentRecords.file?(notes)
    assert WardrikStore.keys(store, "agents/") == ["agents/" <> URI.encode_www_form(notes.id)]
  end

  test "reads who holds a name from its claim, before that record reaches this node", %{
    store: store
  } do
    holder = %{id: "agt_elsewhere", org: "acme", owner: "acme", name: "notes", source: :file}
    {:ok, _vsn} = WardrikStore.put(store, "agent_names/acme/notes", holder, if_vsn: nil)

    assert {:error, {:taken, ^holder}} =
             AgentRecords.create(store, owner: "acme", name: "notes", source: :file)

    assert AgentRecords.named(store, "acme", "notes") == {:ok, holder}
    assert WardrikStore.keys(store, "agents/") == []
  end

  test "names a definition's shared workspaces by the IDs of its org's agents", %{store: store} do
    {:ok, runbooks} = AgentRecords.create(store, owner: "acme", name: "runbooks", source: :api)
    shared = %{"a" => "agent:runbooks", "b" => %{"agent" => "agent:runbooks", "mode" => "read"}}
    definition = %{"model" => "m", "workspace" => %{"shared" => shared}}

    assert {:ok, %{"workspace" => %{"shared" => mounts}, "model" => "m"}} =
             AgentRecords.identified(store, "acme", definition)

    assert mounts == %{"a" => runbooks.id, "b" => %{"agent" => runbooks.id, "mode" => "read"}}

    for {org, shared} <- [
          {"globex", shared},
          {"acme", %{"c" => 42}},
          {"acme", %{"d" => "x"}},
          {"acme", %{"e" => "runbooks"}}
        ] do
      assert {:error, "workspace.shared." <> _why} =
               AgentRecords.identified(store, org, %{"workspace" => %{"shared" => shared}})
    end

    assert AgentRecords.identified(store, "acme", %{"model" => "m"}) == {:ok, %{"model" => "m"}}
    assert AgentRecords.name?("triage-2.b_c")
    refute AgentRecords.name?("a/b")
    refute AgentRecords.name?(String.duplicate("a", 65))
  end
end
