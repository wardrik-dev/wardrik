if System.get_env("DATABASE_URL") do
  defmodule WardrikStore.EctoTest do
    use ExUnit.Case, async: true
    use WardrikStore.Conformance
    use WardrikStore.DurableConformance

    alias WardrikStore.TestRepo

    setup_all do
      start_supervised!({TestRepo, url: System.fetch_env!("DATABASE_URL"), log: false})
      migrations = [{1, WardrikStore.TestMigration}]
      Ecto.Migrator.run(TestRepo, migrations, :down, all: true, log: false)

      {:ignore, missing} =
        ExUnit.CaptureLog.with_log(fn -> WardrikStore.Ecto.start_link(TestRepo) end)

      Ecto.Migrator.run(TestRepo, migrations, :up, all: true, log: false)

      store = WardrikStore.Ecto.new(repo: TestRepo)
      start_supervised!({WardrikStore, store})
      %{store: store, missing: missing}
    end

    test "logs that its table is missing, and starts anyway", %{missing: missing} do
      assert missing =~ "run WardrikStore.Ecto.Migration"
    end

    test "has no migration past the versions it knows" do
      assert_raise ArgumentError, ~r/no version 2/, fn ->
        WardrikStore.Ecto.Migration.up(version: 2)
      end
    end
  end
end
