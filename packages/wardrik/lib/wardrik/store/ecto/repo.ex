if Code.ensure_loaded?(Ecto.Adapters.Postgres) do
  defmodule Wardrik.Store.Ecto.Repo do
    @moduledoc """
    The repo a `Wardrik.Store.Ecto` store starts when given a `:url`. A VM runs at most one.

    Its migrations run under a Postgres advisory lock, so nodes migrate one at a time.
    """

    use Ecto.Repo, otp_app: :wardrik, adapter: Ecto.Adapters.Postgres

    @migrations [{1, Wardrik.Store.Ecto.Repo.V1}]

    @doc "Returns the repo's start options for `url`. Adds TLS options if `url` has `ssl=true`."
    @spec options(String.t()) :: keyword()
    def options(url) do
      %URI{host: host, query: query} = parsed = URI.parse(url)
      {ssl, rest} = Map.pop(URI.decode_query(query || ""), "ssl")
      url = URI.to_string(%{parsed | query: if(rest != %{}, do: URI.encode_query(rest))})

      [url: url, log: false] ++ if(ssl == "true", do: [ssl: tls(host)], else: [])
    end

    @impl Ecto.Repo
    def init(_context, config),
      do:
        {:ok,
         Keyword.merge(config,
           migration_source: "wardrik_store_migrations",
           migration_lock: :pg_advisory_lock
         )}

    defp tls(host),
      do: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

    @doc "Runs the migrations the store's table needs. Returns `:ignore`, so it can run as a child."
    @spec migrate() :: :ignore
    def migrate do
      _ran = Ecto.Migrator.run(__MODULE__, @migrations, :up, all: true, log: false)
      :ignore
    end
  end

  defmodule Wardrik.Store.Ecto.Repo.V1 do
    @moduledoc false
    use Ecto.Migration

    def up, do: Wardrik.Store.Ecto.Migration.up(version: 1)
    def down, do: Wardrik.Store.Ecto.Migration.down(version: 1)
  end
end
