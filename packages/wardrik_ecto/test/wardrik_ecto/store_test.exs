defmodule WardrikEcto.StoreTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Ecto.Adapters.SQL
  alias WardrikEcto.Store
  alias WardrikEcto.Test.Repo
  alias WardrikEcto.Test.Services

  @moduletag :postgres

  setup_all do
    :ignore = Store.start_link(repo: Repo)
    :ok
  end

  use Wardrik.Store.Conformance, adapter: WardrikEcto.Store

  defp away(table) do
    SQL.query!(Repo, "ALTER TABLE #{table} RENAME TO #{table}_away")
    on_exit(fn -> SQL.query!(Repo, "ALTER TABLE #{table}_away RENAME TO #{table}") end)
  end

  describe "starting" do
    test "needs a repo, or a url" do
      assert Store.start_link([]) == {:error, {:missing_options, [:repo]}}

      assert Store.start_link(repo: Repo, url: Services.database_url()) ==
               {:error, {:conflicting_options, [:repo, :url]}}
    end

    test "is a supervisor where it starts a repo of its own" do
      refute Map.has_key?(Store.child_spec(repo: Repo), :type)
      assert %{type: :supervisor} = Store.child_spec(url: Services.database_url())
    end

    test "needs the table WardrikEcto.Migration creates" do
      away("wardrik_records")

      assert {:error, {:no_table, "wardrik_records is missing; run WardrikEcto.Migration"}} =
               Store.start_link(repo: Repo)
    end

    test "fails where the repo is not running" do
      assert {:error, %RuntimeError{}} = Store.start_link(repo: WardrikEcto.StoreTest.Idle)
      assert {:error, %RuntimeError{}} = Store.migrated(WardrikEcto.StoreTest.Idle)
    end

    test "with a url, starts a repo of its own and creates the table" do
      # Run in reverse: the new tables go, the suite's comes back, and the
      # store is kept through the suite's repo again.
      on_exit(fn -> :ignore = Store.start_link(repo: Repo) end)
      away("wardrik_records")
      SQL.query!(Repo, "DROP TABLE IF EXISTS wardrik_schema_migrations")

      on_exit(fn ->
        SQL.query!(Repo, "DROP TABLE IF EXISTS wardrik_records, wardrik_schema_migrations")
      end)

      start_supervised!(Store.child_spec(url: Services.database_url()))

      key = unique()
      assert {:ok, vsn} = Store.put(:own, key, :value, if_vsn: nil)
      assert Store.lookup(:own, key) == {:value, vsn}

      assert %{rows: [[1]]} =
               SQL.query!(WardrikEcto.Repo, "SELECT version FROM wardrik_schema_migrations")
    end

    test "a call before it starts says so" do
      :persistent_term.erase({Store, :repo})
      on_exit(fn -> :ignore = Store.start_link(repo: Repo) end)

      assert_raise ArgumentError, "WardrikEcto.Store was not started", fn ->
        Store.get(:none, "k", [])
      end
    end
  end

  describe "a write whose answer is lost" do
    test "is answered as written where it landed" do
      expect(SQL, :query, fn repo, sql, args ->
        {:ok, _landed} = call_original(SQL, :query, [repo, sql, args])
        {:error, %DBConnection.ConnectionError{message: "lost"}}
      end)

      key = unique()
      assert {:ok, vsn} = Store.put(:lost, key, :value, if_vsn: nil)
      assert Store.lookup(:lost, key) == {:value, vsn}
    end

    test "fails where it did not land, and conflicts where the condition no longer holds" do
      key = unique()
      {:ok, first} = Store.put(:lost, key, :first, [])
      lost = {:error, %DBConnection.ConnectionError{message: "lost"}}

      expect(SQL, :query, fn _repo, _sql, _args -> lost end)
      assert ^lost = Store.put(:lost, key, :second, if_vsn: first)

      {:ok, _second} = Store.put(:lost, key, :second, if_vsn: first)
      expect(SQL, :query, fn _repo, _sql, _args -> lost end)
      assert {:error, :conflict} = Store.put(:lost, key, :third, if_vsn: first)

      expect(SQL, :query, fn _repo, _sql, _args -> lost end)
      assert ^lost = Store.put(:lost, unique(), :value, if_vsn: nil)
    end
  end

  test "fails a delete the database refuses" do
    expect(SQL, :query, fn _repo, _sql, _args -> {:error, :closed} end)
    assert Store.delete(:refused, unique(), []) == {:error, :closed}
  end

  test "a version from elsewhere matches nothing" do
    key = unique()
    {:ok, _vsn} = Store.put(:foreign, key, :value, [])
    assert {:error, :conflict} = Store.delete(:foreign, key, if_vsn: "not a version")
  end

  test "names Wardrik.Store.Durable to hold a fleet" do
    assert Store.durable_backend([]) ==
             {Wardrik.Store.Durable, store: Store, discovery_interval_ms: 5_000}
  end

  describe "check/1" do
    test "finds the table through the repo" do
      assert Store.check(repo: Repo) ==
               {:ok, "the table wardrik_records through WardrikEcto.Test.Repo is there"}
    end

    test "says where the repo has no table, or does not answer" do
      assert {:error, found} = Store.check(repo: WardrikEcto.StoreTest.Idle)

      assert found =~
               "the table wardrik_records through WardrikEcto.StoreTest.Idle: could not lookup"

      away("wardrik_records")

      assert Store.check(repo: Repo) ==
               {:error,
                "the table wardrik_records through WardrikEcto.Test.Repo is missing; " <>
                  "run WardrikEcto.Migration"}
    end

    test "connects to the database a url names" do
      where = "the database wardrik_test on 127.0.0.1:54329"
      assert Store.check(url: Services.database_url()) == {:ok, "#{where} holds wardrik_records"}

      away("wardrik_records")

      assert Store.check(url: Services.database_url()) ==
               {:ok, "#{where} answers, and wardrik_records is made as the store starts"}
    end

    test "says why it cannot connect" do
      wrong = String.replace(Services.database_url(), ":postgres@", ":wrong@")
      assert {:error, found} = Store.check(url: wrong)
      assert found =~ "password authentication failed"

      assert {:error, "invalid URL nowhere" <> _rest} = Store.check(url: "nowhere")
    end

    test "needs a repo or a url, not both" do
      assert Store.check([]) == {:error, "the store names no repo or url"}

      assert Store.check(repo: Repo, url: Services.database_url()) ==
               {:error, "the store names both a repo and a url"}
    end

    test "needs no other node" do
      assert Store.quorum(3) == 1
    end
  end

  describe "WardrikEcto.Migration" do
    test "drops the table, and creates it again" do
      Ecto.Migrator.run(Repo, [{1, WardrikEcto.Test.Migration}], :down, all: true, log: false)
      assert %{rows: [[nil]]} = SQL.query!(Repo, "SELECT to_regclass('wardrik_records')::text")

      Ecto.Migrator.run(Repo, [{1, WardrikEcto.Test.Migration}], :up, all: true, log: false)

      assert %{rows: [["wardrik_records"]]} =
               SQL.query!(Repo, "SELECT to_regclass('wardrik_records')::text")
    end

    test "has only the versions it describes" do
      assert_raise ArgumentError, "WardrikEcto.Migration has no version 2", fn ->
        WardrikEcto.Migration.up(version: 2)
      end
    end
  end

  defp unique, do: "ecto-test/#{System.unique_integer([:positive])}"
end

defmodule WardrikEcto.StoreTest.Idle do
  use Ecto.Repo, otp_app: :wardrik, adapter: Ecto.Adapters.Postgres
end
