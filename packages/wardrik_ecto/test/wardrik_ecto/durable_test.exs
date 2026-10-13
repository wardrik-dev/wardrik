defmodule WardrikEcto.DurableTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  test "holds a DurableServer in Postgres through a restart" do
    store = WardrikStore.new(adapter: WardrikEcto.Store, repo: WardrikEcto.Test.Repo)
    start_supervised!({WardrikStore, store})
    WardrikStore.Test.Durable.survives_a_restart(store, :durable_over_postgres)
  end
end
