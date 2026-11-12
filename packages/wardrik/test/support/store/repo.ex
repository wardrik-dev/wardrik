defmodule WardrikStore.TestRepo do
  @moduledoc "The repo `WardrikStore.Ecto`'s tests run on, over `DATABASE_URL`."
  use Ecto.Repo, otp_app: :wardrik_store, adapter: Ecto.Adapters.Postgres
end

defmodule WardrikStore.TestMigration do
  @moduledoc "Runs `WardrikStore.Ecto.Migration` in the tests."
  use Ecto.Migration

  def up, do: WardrikStore.Ecto.Migration.up(version: 1)
  def down, do: WardrikStore.Ecto.Migration.down(version: 1)
end
