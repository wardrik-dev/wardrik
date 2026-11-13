if System.get_env("DATABASE_URL") do
  defmodule Wardrik.Store.EctoTest do
    use ExUnit.Case, async: true
    use Wardrik.Store.Conformance
    use Wardrik.Store.DurableConformance

    alias Wardrik.Store.TestRepo

    setup_all do
      # A schema of their own, so dropping the table never pulls it from the suite's other tests.
      start_supervised!(
        {TestRepo,
         url: System.fetch_env!("DATABASE_URL"),
         log: false,
         parameters: [search_path: "wardrik_ecto_test"]}
      )

      Ecto.Adapters.SQL.query!(TestRepo, "CREATE SCHEMA IF NOT EXISTS wardrik_ecto_test")
      migrations = [{1, Wardrik.Store.TestMigration}]
      Ecto.Migrator.run(TestRepo, migrations, :down, all: true, log: false)

      {:ignore, missing} =
        ExUnit.CaptureLog.with_log(fn -> Wardrik.Store.Ecto.start_link(TestRepo) end)

      Ecto.Migrator.run(TestRepo, migrations, :up, all: true, log: false)

      store = Wardrik.Store.Ecto.new(repo: TestRepo)
      start_supervised!({Wardrik.Store, store})
      %{store: store, missing: missing}
    end

    test "logs that its table is missing, and starts anyway", %{missing: missing} do
      assert missing =~ "run Wardrik.Store.Ecto.Migration"
    end

    test "has no migration past the versions it knows" do
      assert_raise ArgumentError, ~r/no version 3/, fn ->
        Wardrik.Store.Ecto.Migration.up(version: 3)
      end
    end
  end
end
