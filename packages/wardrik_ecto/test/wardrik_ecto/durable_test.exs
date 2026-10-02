defmodule WardrikEcto.DurableTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  test "holds a DurableServer in Postgres through a restart" do
    :ignore = WardrikEcto.Store.start_link(repo: Wardrik.Test.Repo)
    Wardrik.Test.Durable.survives_a_restart(WardrikEcto.Store, :durable_over_postgres)
  end
end
