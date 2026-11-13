if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule Wardrik.Store.Ecto do
    @moduledoc """
    Keeps keys in a Postgres table.

        # Through your app's repo
        store = Wardrik.Store.Ecto.new(repo: MyApp.Repo)
        children = [MyApp.Repo, {Wardrik.Store, store}]

        # Through a repo of its own
        store = Wardrik.Store.Ecto.new(url: "postgres://user:pass@db.example.com/wardrik?ssl=true")
        children = [{Wardrik.Store, store}]

      * With `:repo`, create the table with `Wardrik.Store.Ecto.Migration`. A missing table logs an
        error, but your app still boots.
      * With `:url`, it starts `Wardrik.Store.Ecto.Repo` and creates the table itself.
      * `?ssl=true` connects over TLS, verified against the system's certificates.
    """

    @behaviour Wardrik.Store.Adapter

    alias Ecto.Adapters.SQL

    require Logger

    @table "wardrik_store"

    defmodule Own do
      @moduledoc false
      @derive {Inspect, only: []}
      @enforce_keys [:url]
      defstruct [:url]
    end

    @doc """
    Builds a store. Starts nothing.

    ## Options

    Give one of:

      * `:repo` - your app's repo. Point it at the primary, not a replica.
      * `:url` - a Postgres URL for a repo of its own.

    Raises `ArgumentError` if given both or neither.
    """
    @spec new(keyword()) :: Wardrik.Store.t()
    def new(opts) do
      case Keyword.take(opts, [:repo, :url]) do
        [repo: repo] ->
          Wardrik.Store.new(__MODULE__, repo)

        [url: url] ->
          Wardrik.Store.new(__MODULE__, %Own{url: url})

        _neither_or_both ->
          raise ArgumentError, "Give Wardrik.Store.Ecto a :repo or a :url, not both."
      end
    end

    @doc "Checks the store's table exists in `repo`. Logs an error if it doesn't. Returns `:ignore`."
    @spec start_link(module()) :: :ignore
    def start_link(repo) do
      case SQL.query(repo, "SELECT to_regclass($1)::text", [@table]) do
        {:ok, %{rows: [[@table]]}} -> :ok
        {:ok, _missing} -> Logger.error("#{@table} is missing; run Wardrik.Store.Ecto.Migration")
        {:error, reason} -> Logger.error("Couldn't check #{@table} is there: #{inspect(reason)}")
      end

      :ignore
    end

    @impl Wardrik.Store.Adapter
    def child_spec(%Own{url: url}) do
      children = [
        {Wardrik.Store.Ecto.Repo, Wardrik.Store.Ecto.Repo.options(url)},
        %{id: :migrated, start: {Wardrik.Store.Ecto.Repo, :migrate, []}}
      ]

      %{
        id: __MODULE__,
        start:
          {Supervisor, :start_link,
           [children, [strategy: :rest_for_one, name: Module.concat(__MODULE__, Supervisor)]]},
        type: :supervisor
      }
    end

    def child_spec(repo), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [repo]}}

    @impl Wardrik.Store.Adapter
    def put(%Own{}, path, value, opts), do: put(Wardrik.Store.Ecto.Repo, path, value, opts)

    def put(repo, path, value, opts) do
      vsn = :rand.uniform(0x7FFFFFFFFFFFFFFF)
      condition = Keyword.fetch(opts, :if_vsn)

      case written(repo, condition, [path, value, vsn]) do
        {:ok, %{num_rows: 1}} -> {:ok, vsn}
        {:ok, %{num_rows: 0}} -> {:error, :conflict}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Wardrik.Store.Adapter
    def lookup(%Own{}, path), do: lookup(Wardrik.Store.Ecto.Repo, path)

    def lookup(repo, path) do
      case SQL.query!(repo, "SELECT value::text, vsn FROM #{@table} WHERE key = $1", [path]) do
        %{rows: [[value, vsn]]} -> {value, vsn}
        %{rows: []} -> nil
      end
    end

    @impl Wardrik.Store.Adapter
    def delete(%Own{}, path, opts), do: delete(Wardrik.Store.Ecto.Repo, path, opts)

    def delete(repo, path, opts) do
      case removed(repo, Keyword.fetch(opts, :if_vsn), path) do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, %{num_rows: 0}} -> gone_or_conflict(repo, path)
        {:error, reason} -> {:error, reason}
      end
    end

    @impl Wardrik.Store.Adapter
    def keys(%Own{}, prefix), do: keys(Wardrik.Store.Ecto.Repo, prefix)

    def keys(repo, prefix) do
      %{rows: rows} =
        SQL.query!(
          repo,
          "SELECT key FROM #{@table} WHERE key LIKE $1 ESCAPE '\\' ORDER BY key",
          [like(prefix) <> "%"]
        )

      Enum.map(rows, fn [key] -> key end)
    end

    @impl Wardrik.Store.Adapter
    def lookup_many(%Own{}, paths), do: lookup_many(Wardrik.Store.Ecto.Repo, paths)

    def lookup_many(repo, paths) do
      %{rows: rows} =
        SQL.query!(repo, "SELECT key, value::text, vsn FROM #{@table} WHERE key = ANY($1)", [
          paths
        ])

      for [key, value, vsn] <- rows, do: {key, value, vsn}
    end

    @impl Wardrik.Store.Adapter
    def entries(%Own{}, prefix), do: entries(Wardrik.Store.Ecto.Repo, prefix)

    def entries(repo, prefix) do
      %{rows: rows} =
        SQL.query!(
          repo,
          "SELECT key, value::text, vsn FROM #{@table} WHERE key LIKE $1 ESCAPE '\\' ORDER BY key",
          [like(prefix) <> "%"]
        )

      for [key, value, vsn] <- rows, do: {key, value, vsn}
    end

    @impl Wardrik.Store.Adapter
    def versions(%Own{}, prefix), do: versions(Wardrik.Store.Ecto.Repo, prefix)

    def versions(repo, prefix) do
      %{rows: rows} =
        SQL.query!(
          repo,
          "SELECT key, vsn FROM #{@table} WHERE key LIKE $1 ESCAPE '\\' ORDER BY key",
          [like(prefix) <> "%"]
        )

      for [key, vsn] <- rows, do: {key, vsn}
    end

    defp written(repo, :error, args) do
      SQL.query(
        repo,
        """
        INSERT INTO #{@table} (key, value, vsn) VALUES ($1, $2::text::jsonb, $3)
        ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, vsn = EXCLUDED.vsn
        """,
        args
      )
    end

    defp written(repo, {:ok, nil}, args) do
      SQL.query(
        repo,
        "INSERT INTO #{@table} (key, value, vsn) VALUES ($1, $2::text::jsonb, $3) ON CONFLICT (key) DO NOTHING",
        args
      )
    end

    defp written(repo, {:ok, vsn}, args) when is_integer(vsn) do
      SQL.query(
        repo,
        "UPDATE #{@table} SET value = $2::text::jsonb, vsn = $3 WHERE key = $1 AND vsn = $4",
        args ++ [vsn]
      )
    end

    defp written(_repo, {:ok, _not_a_vsn}, _args), do: {:ok, %{num_rows: 0}}

    defp removed(repo, :error, path),
      do: SQL.query(repo, "DELETE FROM #{@table} WHERE key = $1", [path])

    defp removed(repo, {:ok, vsn}, path) when is_integer(vsn),
      do: SQL.query(repo, "DELETE FROM #{@table} WHERE key = $1 AND vsn = $2", [path, vsn])

    defp removed(_repo, {:ok, _not_a_vsn}, _path), do: {:ok, %{num_rows: 0}}

    defp gone_or_conflict(repo, path) do
      if lookup(repo, path) == nil, do: :ok, else: {:error, :conflict}
    end

    defp like(prefix), do: String.replace(prefix, ~r/[\\%_]/, "\\\\\\0")
  end
end
