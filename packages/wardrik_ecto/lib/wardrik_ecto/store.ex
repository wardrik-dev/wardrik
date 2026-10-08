# Compiled only where the application has :ecto_sql and :postgrex, which are
# optional.
if Code.ensure_loaded?(Ecto.Adapters.SQL) and Code.ensure_loaded?(Postgrex) do
  defmodule WardrikEcto.Store do
    @moduledoc """
    A `Wardrik.Store` in a Postgres table, through a host's Ecto repo or one of
    its own.

        {Wardrik, store: [adapter: WardrikEcto.Store, repo: MyApp.Repo]}

    The table is `wardrik_records`, which `WardrikEcto.Migration` creates. A row
    is a namespace, a key, a value written with `:erlang.term_to_binary/1` and
    read back with `:safe`, and a version: a random 63-bit integer each write
    draws, so a version once written over is current again only by a chance of
    one in 2^63.

    A write where nothing is written is `INSERT … ON CONFLICT DO NOTHING`, a
    write over a version is `UPDATE … WHERE vsn = …`, and each is one statement,
    so Postgres alone decides between two writers. A write whose answer never
    arrived is read back: it landed where the row holds its version.

    Reads go to the repo, so a repo that reads from a replica answers what the
    replica holds. Name the primary.

    ## Its repo

    The store is kept through a host's repo, or through one of its own:

        {Wardrik, store: [adapter: WardrikEcto.Store, url: "postgres://…/wardrik"]}

    | Option | Default | |
    | --- | --- | --- |
    | `:repo` | | an `Ecto.Repo` over Postgres, started before the store is |
    | `:url` | | the database, for `WardrikEcto.Repo`, which the store starts itself |
    | `:discovery_interval_ms` | 5s | how often a node looks for agents no node holds |

    One of `:repo` and `:url` is required. A host's repo starts before `Wardrik`
    does; see `Wardrik`. The host creates the table from a migration of its own,
    with `WardrikEcto.Migration`, and the store fails to start, saying so, where
    the repo does not answer or the table is not there.

    With `:url` the store starts `WardrikEcto.Repo` and runs
    `WardrikEcto.Migration` before anything is kept, holding a Postgres advisory
    lock while it does, so nodes starting at once migrate one at a time. The
    migration is recorded in `wardrik_schema_migrations`. `?ssl=true` in the URL
    connects over TLS, checked against the system's certificates.
    """

    @behaviour Wardrik.Store

    alias Ecto.Adapters.SQL
    alias WardrikEcto.Connection
    alias WardrikEcto.Repo

    @config {__MODULE__, :repo}
    @table "wardrik_records"
    @migrations [{1, WardrikEcto.Migration}]
    @migration_lock :erlang.phash2({__MODULE__, :migration})

    @impl Wardrik.Store
    def child_spec(opts) do
      spec = %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
      if Keyword.has_key?(opts, :url), do: Map.put(spec, :type, :supervisor), else: spec
    end

    @doc """
    With `:repo`, checks the repo and the table as the module describes, and
    keeps the repo for every call after; nothing runs, so it answers `:ignore`.
    With `:url`, starts `WardrikEcto.Repo`, migrates it, and does the same over
    it, under a supervisor it answers.
    """
    @spec start_link(keyword()) :: Supervisor.on_start() | :ignore
    def start_link(opts) do
      case {Keyword.fetch(opts, :repo), Keyword.fetch(opts, :url)} do
        {{:ok, repo}, :error} when is_atom(repo) ->
          ready(repo)

        {:error, {:ok, url}} when is_binary(url) ->
          Supervisor.start_link(
            [{Repo, url: url}, %{id: :migrated, start: {__MODULE__, :migrated, [Repo]}}],
            strategy: :rest_for_one
          )

        {{:ok, _repo}, {:ok, _url}} ->
          {:error, {:conflicting_options, [:repo, :url]}}

        _missing ->
          {:error, {:missing_options, [:repo]}}
      end
    end

    @doc false
    @spec migrated(module()) :: :ignore | {:error, term()}
    def migrated(repo) do
      with :ok <- migrate(repo), do: ready(repo)
    end

    defp ready(repo) do
      with :ok <- table?(repo) do
        :persistent_term.put(@config, repo)
        :ignore
      end
    end

    defp table?(repo) do
      case SQL.query(repo, "SELECT to_regclass($1)::text", [@table]) do
        {:ok, %{rows: [[@table]]}} ->
          :ok

        {:ok, _no_table} ->
          {:error, {:no_table, "#{@table} is missing; run WardrikEcto.Migration"}}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error in [DBConnection.ConnectionError, RuntimeError] -> {:error, error}
    end

    # The lock is a session's, so the connection that takes it is checked out
    # until it is released. The migration itself runs on another.
    defp migrate(repo) do
      repo.checkout(fn ->
        SQL.query!(repo, "SELECT pg_advisory_lock($1)", [@migration_lock])

        try do
          Ecto.Migrator.run(repo, @migrations, :up, all: true, log: false)
        after
          SQL.query!(repo, "SELECT pg_advisory_unlock($1)", [@migration_lock])
        end
      end)

      :ok
    rescue
      error in [DBConnection.ConnectionError, Postgrex.Error, RuntimeError] -> {:error, error}
    end

    @doc """
    With `:url`, connects to the database once, and answers whether it holds the
    table or has it made as the store starts. With `:repo`, asks the repo, which
    must be running, for the table.
    """
    @impl Wardrik.Store
    def check(opts) do
      case {Keyword.fetch(opts, :repo), Keyword.fetch(opts, :url)} do
        {{:ok, repo}, :error} -> check_repo(repo)
        {:error, {:ok, url}} -> check_url(url)
        {{:ok, _repo}, {:ok, _url}} -> {:error, "the store names both a repo and a url"}
        {:error, :error} -> {:error, "the store names no repo or url"}
      end
    end

    defp check_repo(repo) do
      where = "the table #{@table} through #{inspect(repo)}"

      case table?(repo) do
        :ok ->
          {:ok, "#{where} is there"}

        {:error, {:no_table, _message}} ->
          {:error, "#{where} is missing; run WardrikEcto.Migration"}

        {:error, reason} ->
          {:error, "#{where}: #{describe(reason)}"}
      end
    end

    defp check_url(url) do
      config = Ecto.Repo.Supervisor.parse_url(url)
      where = "the database #{config[:database]} on #{config[:hostname]}:#{config[:port] || 5432}"

      case Connection.query(config, "SELECT to_regclass('#{@table}')::text") do
        {:ok, [[@table]]} -> {:ok, "#{where} holds #{@table}"}
        {:ok, _no_table} -> {:ok, "#{where} answers, and #{@table} is made as the store starts"}
        {:error, reason} -> {:error, "#{where}: #{describe(reason)}"}
      end
    rescue
      error in Ecto.InvalidURLError -> {:error, Exception.message(error)}
    end

    defp describe(%{__exception__: true} = error), do: Exception.message(error)
    defp describe(reason) when is_binary(reason), do: reason
    defp describe(reason), do: inspect(reason)

    @impl Wardrik.Store
    def quorum(_size), do: 1

    @impl Wardrik.Store
    def durable_backend(opts) do
      {Wardrik.Store.Durable,
       store: __MODULE__, discovery_interval_ms: Keyword.get(opts, :discovery_interval_ms, 5_000)}
    end

    @impl Wardrik.Store
    def put(ns, key, value, opts) do
      vsn = vsn()
      condition = Keyword.fetch(opts, :if_vsn)
      args = [to_string(ns), key, :erlang.term_to_binary(value), vsn]

      case query(write(condition), args ++ condition_args(condition)) do
        {:ok, %{num_rows: 1}} -> {:ok, vsn}
        {:ok, %{num_rows: 0}} -> {:error, :conflict}
        {:error, reason} -> confirmed(ns, key, vsn, condition, reason)
      end
    end

    defp write(:error) do
      """
      INSERT INTO #{@table} (ns, key, value, vsn) VALUES ($1, $2, $3, $4)
      ON CONFLICT (ns, key) DO UPDATE SET value = EXCLUDED.value, vsn = EXCLUDED.vsn
      """
    end

    defp write({:ok, nil}) do
      """
      INSERT INTO #{@table} (ns, key, value, vsn) VALUES ($1, $2, $3, $4)
      ON CONFLICT (ns, key) DO NOTHING
      """
    end

    defp write({:ok, _vsn}),
      do: "UPDATE #{@table} SET value = $3, vsn = $4 WHERE ns = $1 AND key = $2 AND vsn = $5"

    defp condition_args({:ok, vsn}) when is_integer(vsn), do: [vsn]
    defp condition_args(_condition), do: []

    # The write may or may not have landed. What the row holds says which.
    defp confirmed(ns, key, vsn, condition, reason) do
      case lookup(ns, key) do
        {_value, ^vsn} -> {:ok, vsn}
        nil when condition in [:error, {:ok, nil}] -> {:error, reason}
        {_value, current} when condition in [:error, {:ok, current}] -> {:error, reason}
        _condition_ruled_out -> {:error, :conflict}
      end
    end

    @impl Wardrik.Store
    def get(ns, key, _opts) do
      case lookup(ns, key) do
        {value, _vsn} -> value
        nil -> nil
      end
    end

    @impl Wardrik.Store
    def lookup(ns, key) do
      case query!("SELECT value, vsn FROM #{@table} WHERE ns = $1 AND key = $2", [
             to_string(ns),
             key
           ]) do
        %{rows: [[value, vsn]]} -> {:erlang.binary_to_term(value, [:safe]), vsn}
        %{rows: []} -> nil
      end
    end

    @impl Wardrik.Store
    def delete(ns, key, opts) do
      args = [to_string(ns), key]

      result =
        case Keyword.fetch(opts, :if_vsn) do
          {:ok, vsn} when is_integer(vsn) ->
            query("DELETE FROM #{@table} WHERE ns = $1 AND key = $2 AND vsn = $3", args ++ [vsn])

          {:ok, _not_a_version} ->
            {:ok, %{num_rows: 0}}

          :error ->
            query("DELETE FROM #{@table} WHERE ns = $1 AND key = $2", args)
        end

      case result do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, %{num_rows: 0}} -> if lookup(ns, key) == nil, do: :ok, else: {:error, :conflict}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Wardrik.Store
    def keys(ns, prefix) do
      %{rows: rows} =
        query!(
          "SELECT key FROM #{@table} WHERE ns = $1 AND key LIKE $2 ESCAPE '\\' ORDER BY key",
          [to_string(ns), like(prefix) <> "%"]
        )

      Enum.map(rows, fn [key] -> key end)
    end

    defp like(prefix), do: String.replace(prefix, ~r/[\\%_]/, "\\\\\\0")

    defp vsn, do: :rand.uniform(0x7FFFFFFFFFFFFFFF)

    defp query(sql, args) do
      SQL.query(repo(), sql, args)
    rescue
      error in DBConnection.ConnectionError -> {:error, error}
    end

    defp query!(sql, args), do: SQL.query!(repo(), sql, args)

    defp repo do
      with nil <- :persistent_term.get(@config, nil) do
        raise ArgumentError, "WardrikEcto.Store was not started"
      end
    end
  end
end
