defmodule WardrikEcto.Store do
  @moduledoc """
  A `Wardrik.Store` in a Postgres table, through an Ecto repo the host owns.

      config :wardrik, Wardrik.Store, adapter: WardrikEcto.Store, repo: MyApp.Repo

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

  | Option | Default | |
  | --- | --- | --- |
  | `:repo` | required | an `Ecto.Repo` over Postgres, started before the store is |
  | `:discovery_interval_ms` | 5s | how often a node looks for agents no node holds |

  `child_spec/1` checks that the repo answers and the table is there, and
  fails to start, saying so, where either is not.
  """

  @behaviour Wardrik.Store

  alias Ecto.Adapters.SQL

  @config {__MODULE__, :repo}
  @table "wardrik_records"

  @impl Wardrik.Store
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Checks the repo and the table as the module describes, and keeps the repo
  for every call after. Nothing runs, so it answers `:ignore`.
  """
  @spec start_link(keyword()) :: :ignore | {:error, term()}
  def start_link(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} when is_atom(repo) ->
        with :ok <- table?(repo) do
          :persistent_term.put(@config, repo)
          :ignore
        end

      _missing ->
        {:error, {:missing_options, [:repo]}}
    end
  end

  defp table?(repo) do
    case SQL.query(repo, "SELECT to_regclass($1)::text", [@table]) do
      {:ok, %{rows: [[@table]]}} -> :ok
      {:ok, _no_table} -> {:error, {:no_table, "#{@table} is missing; run WardrikEcto.Migration"}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in [DBConnection.ConnectionError, RuntimeError] -> {:error, error}
  end

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
