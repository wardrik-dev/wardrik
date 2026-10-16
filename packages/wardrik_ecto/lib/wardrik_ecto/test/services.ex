# Compiled only where the application has :ecto_sql and :postgrex, which are
# optional.
if Code.ensure_loaded?(Ecto.Adapters.SQL) and Code.ensure_loaded?(Postgrex) do
  defmodule WardrikEcto.Test.Services do
    @moduledoc """
    The database the `:postgres` tests reach, where the environment names one or
    `dev/services.sh` started it.
    """

    alias WardrikEcto.Test.Repo

    @doc "Where the suite's database is."
    @spec database_url() :: String.t()
    def database_url,
      do:
        System.get_env(
          "WARDRIK_TEST_DATABASE_URL",
          "postgres://postgres:postgres@127.0.0.1:54329/wardrik_test"
        )

    @doc """
    Starts the database where it answers, and names the tag of its tests where
    it does not, for the suite to exclude. Where `WARDRIK_TEST_SERVICES` is
    `required`, a database that does not answer raises instead.
    """
    @spec start() :: [atom()]
    def start do
      cond do
        reachable?(database_url()) ->
          start_postgres!()
          []

        System.get_env("WARDRIK_TEST_SERVICES") == "required" ->
          raise "the :postgres tests need #{database_url()}, and nothing answers there"

        true ->
          IO.puts(
            :stderr,
            "Skipping the :postgres tests: nothing answers at #{database_url()}. dev/services.sh starts it."
          )

          [:postgres]
      end
    end

    @doc "Whether anything answers at `url`'s host and port."
    @spec reachable?(String.t()) :: boolean()
    def reachable?(url) do
      %URI{host: host, port: port} = URI.parse(url)

      case :gen_tcp.connect(String.to_charlist(host), port, [], 500) do
        {:ok, socket} -> :gen_tcp.close(socket) == :ok
        {:error, _reason} -> false
      end
    end

    @doc "Creates the suite's database where it is missing, starts the repo, and migrates it."
    @spec start_postgres!() :: true
    def start_postgres! do
      config = Ecto.Repo.Supervisor.parse_url(database_url()) ++ [pool_size: 10, log: false]
      Application.put_env(:wardrik_ecto, Repo, config)

      case Ecto.Adapters.Postgres.storage_up(config) do
        :ok -> :ok
        {:error, :already_up} -> :ok
      end

      {:ok, _pid} = Repo.start_link()

      _migrated =
        Ecto.Migrator.run(Repo, [{1, WardrikEcto.Test.Migration}], :up, all: true, log: false)

      true
    end
  end
end
