defmodule WardrikEcto.Repo do
  @moduledoc """
  The repo `WardrikEcto.Store` starts for itself when it is given a `:url`
  rather than a host's `:repo`. Its queries are not logged, and its migrations
  are recorded in `wardrik_schema_migrations`, apart from any other
  application's in the same database.
  """

  use Ecto.Repo, otp_app: :wardrik, adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_context, config),
    do: {:ok, Keyword.merge(config, log: false, migration_source: "wardrik_schema_migrations")}
end
