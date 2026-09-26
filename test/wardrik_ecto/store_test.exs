defmodule WardrikEcto.StoreTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Ecto.Adapters.SQL
  alias Wardrik.Test.Repo
  alias WardrikEcto.Store

  @moduletag :postgres

  setup_all do
    :ignore = Store.start_link(repo: Repo)
    :ok
  end

  use Wardrik.Store.Conformance, adapter: WardrikEcto.Store

  describe "starting" do
    test "needs a repo" do
      assert Store.start_link([]) == {:error, {:missing_options, [:repo]}}
    end

    test "needs the table WardrikEcto.Migration creates" do
      SQL.query!(Repo, "ALTER TABLE wardrik_records RENAME TO wardrik_records_away")

      on_exit(fn ->
        SQL.query!(Repo, "ALTER TABLE wardrik_records_away RENAME TO wardrik_records")
      end)

      assert {:error, {:no_table, "wardrik_records is missing; run WardrikEcto.Migration"}} =
               Store.start_link(repo: Repo)
    end

    test "fails where the repo is not running" do
      assert {:error, %RuntimeError{}} = Store.start_link(repo: WardrikEcto.StoreTest.Idle)
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

  describe "WardrikEcto.Migration" do
    test "drops the table, and creates it again" do
      Ecto.Migrator.run(Repo, [{1, Wardrik.Test.Migration}], :down, all: true, log: false)
      assert %{rows: [[nil]]} = SQL.query!(Repo, "SELECT to_regclass('wardrik_records')::text")

      Ecto.Migrator.run(Repo, [{1, Wardrik.Test.Migration}], :up, all: true, log: false)

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
