if Code.ensure_loaded?(Ecto.Migration) do
  defmodule Wardrik.Store.Ecto.Migration do
    @moduledoc """
    Creates the table `Wardrik.Store.Ecto` keeps keys in.

        defmodule MyApp.Repo.Migrations.AddWardrikStore do
          use Ecto.Migration

          def up do
            Wardrik.Store.Ecto.Migration.up(version: 1)
            Wardrik.Store.Ecto.Migration.up(version: 2)
          end

          def down do
            Wardrik.Store.Ecto.Migration.down(version: 2)
            Wardrik.Store.Ecto.Migration.down(version: 1)
          end
        end

    Each version runs once. When a release adds a version, add a migration that runs it.

      * 1 - creates the table.
      * 2 - keeps values as `jsonb`. Fails where the table holds values an earlier release wrote,
        which no release since reads.
    """

    use Ecto.Migration

    @versions [1, 2]

    @doc "Makes what `:version` changes. Raises `ArgumentError` for an unknown version."
    @spec up(keyword()) :: :ok
    def up(opts) do
      opts
      |> version()
      |> change(:up)

      :ok
    end

    @doc "Undoes what `:version` changed. Raises `ArgumentError` for an unknown version."
    @spec down(keyword()) :: :ok
    def down(opts) do
      opts
      |> version()
      |> change(:down)

      :ok
    end

    defp version(opts) do
      version = Keyword.fetch!(opts, :version)

      if version in @versions,
        do: version,
        else:
          raise(ArgumentError, "Wardrik.Store.Ecto.Migration has no version #{inspect(version)}")
    end

    defp change(1, :up) do
      execute("""
      CREATE TABLE IF NOT EXISTS wardrik_store (
        key text COLLATE "C" PRIMARY KEY,
        value bytea NOT NULL,
        vsn bigint NOT NULL
      )
      """)
    end

    defp change(1, :down), do: execute("DROP TABLE IF EXISTS wardrik_store")

    defp change(2, :up) do
      typed("bytea", "ALTER COLUMN value TYPE jsonb USING convert_from(value, 'UTF8')::jsonb")
    end

    defp change(2, :down) do
      typed("jsonb", "ALTER COLUMN value TYPE bytea USING convert_to(value::text, 'UTF8')")
    end

    # Alters the value column only where it has the type `from`, so a version runs once however
    # many repos run it over the table, as version 1's IF NOT EXISTS does.
    defp typed(from, alteration) do
      execute("""
      DO $$
      BEGIN
        IF (SELECT data_type FROM information_schema.columns
            WHERE table_schema = current_schema()
              AND table_name = 'wardrik_store' AND column_name = 'value') = '#{from}' THEN
          ALTER TABLE wardrik_store #{alteration};
        END IF;
      END
      $$
      """)
    end
  end
end
