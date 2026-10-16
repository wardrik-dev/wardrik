# Compiled only where the application has :ecto_sql and :postgrex, which are
# optional.
if Code.ensure_loaded?(WardrikEcto.Migration) do
  defmodule Wardrik.Migration do
    @moduledoc """
    Wardrik's table in an application's Postgres, `wardrik_records`, which a
    migration of the application's own creates, for a store named by its
    `repo:`:

        defmodule MyApp.Repo.Migrations.AddWardrik do
          use Ecto.Migration

          def up, do: Wardrik.Migration.up(version: 1)
          def down, do: Wardrik.Migration.down(version: 1)
        end

    A version is a step in the table's shape: `up/1` takes the table to the
    version named, and `down/1` back to before it. See
    `WardrikEcto.Migration`.
    """

    @doc "Creates what `:version` needs."
    @spec up(keyword()) :: :ok
    defdelegate up(opts), to: WardrikEcto.Migration

    @doc "Drops what `:version` created."
    @spec down(keyword()) :: :ok
    defdelegate down(opts), to: WardrikEcto.Migration
  end
end
