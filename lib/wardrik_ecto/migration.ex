# Compiled only where the application has :ecto_sql and :postgrex, which are
# optional.
if Code.ensure_loaded?(Ecto.Adapters.SQL) and Code.ensure_loaded?(Postgrex) do
  defmodule WardrikEcto.Migration do
    @moduledoc """
    The table `WardrikEcto.Store` keeps, created from a migration of the host's
    own, so it is in the host's migration history.

        defmodule MyApp.Repo.Migrations.AddWardrik do
          use Ecto.Migration

          def up, do: WardrikEcto.Migration.up(version: 1)
          def down, do: WardrikEcto.Migration.down(version: 1)
        end

    A version is a step in the table's shape. `up/1` takes the table to the
    version named, and `down/1` back to before it. Version 1 is the table:

    | Column | Type | |
    | --- | --- | --- |
    | `ns` | `text` | the namespace |
    | `key` | `text`, collated `"C"` | so a prefix is a range of the primary key |
    | `value` | `bytea` | |
    | `vsn` | `bigint` | |

    with `(ns, key)` as its primary key.
    """

    use Ecto.Migration

    @versions [1]

    @doc "Creates what `version`, 1 by default, needs."
    @spec up(keyword()) :: :ok
    def up(opts \\ []) do
      opts |> version() |> change(:up)
      :ok
    end

    @doc "Drops what `version`, 1 by default, created."
    @spec down(keyword()) :: :ok
    def down(opts \\ []) do
      opts |> version() |> change(:down)
      :ok
    end

    defp version(opts) do
      version = Keyword.get(opts, :version, 1)

      if version in @versions,
        do: version,
        else: raise(ArgumentError, "WardrikEcto.Migration has no version #{inspect(version)}")
    end

    defp change(1, :up) do
      execute("""
      CREATE TABLE IF NOT EXISTS wardrik_records (
        ns text NOT NULL,
        key text COLLATE "C" NOT NULL,
        value bytea NOT NULL,
        vsn bigint NOT NULL,
        PRIMARY KEY (ns, key)
      )
      """)
    end

    defp change(1, :down), do: execute("DROP TABLE IF EXISTS wardrik_records")
  end
end
