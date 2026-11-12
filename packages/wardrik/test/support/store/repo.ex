defmodule Wardrik.Store.TestRepo do
  @moduledoc "The repo `Wardrik.Store.Ecto`'s tests run on, over `DATABASE_URL`."
  use Ecto.Repo, otp_app: :wardrik, adapter: Ecto.Adapters.Postgres
end

defmodule Wardrik.Store.TestMigration do
  @moduledoc "Runs `Wardrik.Store.Ecto.Migration` in the tests."
  use Ecto.Migration

  def up, do: Wardrik.Store.Ecto.Migration.up(version: 1)
  def down, do: Wardrik.Store.Ecto.Migration.down(version: 1)
end
