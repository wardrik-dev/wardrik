defmodule WardrikS3.Test.Services do
  @moduledoc """
  The bucket the `:s3` tests reach, where the environment names one or
  `dev/services.sh` started it.
  """

  @doc """
  The options `WardrikStore.new/1` builds a store over the suite's bucket from, under a
  prefix of this run's own. `WARDRIK_TEST_S3_BUCKET` and `WARDRIK_TEST_S3_REGION`
  point it at a bucket elsewhere, on R2 or AWS.
  """
  @spec s3_opts() :: keyword()
  def s3_opts do
    [
      bucket: System.get_env("WARDRIK_TEST_S3_BUCKET", "wardrik-test"),
      endpoint: System.get_env("WARDRIK_TEST_S3_ENDPOINT", "http://127.0.0.1:59000"),
      region: System.get_env("WARDRIK_TEST_S3_REGION", "us-east-1"),
      access_key_id: System.get_env("WARDRIK_TEST_S3_ACCESS_KEY_ID", "wardrik"),
      secret_access_key: System.get_env("WARDRIK_TEST_S3_SECRET_ACCESS_KEY", "wardrik-secret"),
      prefix: "run-#{System.system_time(:millisecond)}"
    ]
  end

  @doc """
  Creates the bucket where it answers, and names the tag of its tests where it
  does not, for the suite to exclude. Where `WARDRIK_TEST_SERVICES` is
  `required`, a bucket that does not answer raises instead.
  """
  @spec start() :: [atom()]
  def start do
    endpoint = s3_opts()[:endpoint]

    cond do
      reachable?(endpoint) ->
        create_bucket!()
        []

      System.get_env("WARDRIK_TEST_SERVICES") == "required" ->
        raise "the :s3 tests need #{endpoint}, and nothing answers there"

      true ->
        IO.puts(
          :stderr,
          "Skipping the :s3 tests: nothing answers at #{endpoint}. dev/services.sh starts it."
        )

        [:s3]
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

  @doc """
  Creates the suite's bucket where it is missing. A bucket
  `WARDRIK_TEST_S3_BUCKET` names is one already there, and left as it is.
  """
  @spec create_bucket!() :: true
  def create_bucket! do
    if System.get_env("WARDRIK_TEST_S3_BUCKET"), do: true, else: create_bucket!(s3_opts())
  end

  defp create_bucket!(opts) do
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
