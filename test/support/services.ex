defmodule Wardrik.Test.Services do
  @moduledoc """
  The services the `:postgres` and `:s3` tests reach, where the environment
  names them or `dev/services.sh` started them.
  """

  alias Wardrik.Test.Repo

  @doc "Where the suite's database is."
  @spec database_url() :: String.t()
  def database_url,
    do:
      System.get_env(
        "WARDRIK_TEST_DATABASE_URL",
        "postgres://postgres:postgres@127.0.0.1:54329/wardrik_test"
      )

  @doc "What `WardrikS3.Store.start_link/1` takes to reach the suite's bucket, under a prefix of this run's own."
  @spec s3_opts() :: keyword()
  def s3_opts do
    [
      bucket: "wardrik-test",
      endpoint: System.get_env("WARDRIK_TEST_S3_ENDPOINT", "http://127.0.0.1:59000"),
      access_key_id: System.get_env("WARDRIK_TEST_S3_ACCESS_KEY_ID", "wardrik"),
      secret_access_key: System.get_env("WARDRIK_TEST_S3_SECRET_ACCESS_KEY", "wardrik-secret"),
      prefix: "run-#{System.system_time(:millisecond)}"
    ]
  end

  @doc """
  Starts each service that answers, and names the tags of those that do not,
  for the suite to exclude. Where `WARDRIK_TEST_SERVICES` is `required`, one
  that does not answer raises instead.
  """
  @spec start() :: [atom()]
  def start do
    for {tag, url, start} <- [
          {:postgres, database_url(), &start_postgres!/0},
          {:s3, s3_opts()[:endpoint], &create_bucket!/0}
        ],
        not up?(tag, url, start),
        do: tag
  end

  defp up?(tag, url, start) do
    cond do
      reachable?(url) ->
        start.()

      System.get_env("WARDRIK_TEST_SERVICES") == "required" ->
        raise "the #{inspect(tag)} tests need #{url}, and nothing answers there"

      true ->
        IO.puts(
          :stderr,
          "Skipping the #{inspect(tag)} tests: nothing answers at #{url}. dev/services.sh starts it."
        )

        false
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
    Application.put_env(:wardrik, Repo, config)

    case Ecto.Adapters.Postgres.storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
    end

    {:ok, _pid} = Repo.start_link()
    _migrated = Ecto.Migrator.run(Repo, [{1, Wardrik.Test.Migration}], :up, all: true, log: false)
    true
  end

  @doc "Creates the suite's bucket where it is missing."
  @spec create_bucket!() :: true
  def create_bucket! do
    opts = s3_opts()

    %{status: status} =
      Req.put!(
        Req.new(
          base_url: opts[:endpoint],
          aws_sigv4: [
            access_key_id: opts[:access_key_id],
            secret_access_key: opts[:secret_access_key],
            service: :s3
          ],
          retry: false
        ),
        url: "/" <> opts[:bucket]
      )

    true = status in [200, 409]
  end
end
