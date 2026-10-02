defmodule WardrikEcto.Test.Repo do
  @moduledoc "The Postgres repo the suite's `:postgres` tests keep `WardrikEcto.Store` in."

  use Ecto.Repo, otp_app: :wardrik_ecto, adapter: Ecto.Adapters.Postgres
end

defmodule WardrikEcto.Test.Migration do
  @moduledoc "A host's migration, as `WardrikEcto.Migration` asks for one."

  use Ecto.Migration

  def up, do: WardrikEcto.Migration.up(version: 1)
  def down, do: WardrikEcto.Migration.down(version: 1)
end
