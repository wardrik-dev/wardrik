if System.get_env("DATABASE_URL") do
  defmodule Wardrik.Store.EctoURLTest do
    use ExUnit.Case, async: false
    use Wardrik.Store.Conformance

    alias Ecto.Adapters.Postgres
    alias Ecto.Adapters.SQL
    alias Wardrik.Store
    alias Wardrik.Store.Ecto.Repo

    setup_all do
      url =
        "DATABASE_URL"
        |> System.fetch_env!()
        |> String.replace(~r{/[^/?]+(\?|$)}, "/wardrik_store_url\\1", global: false)

      database = Ecto.Repo.Supervisor.parse_url(url)
      _dropped = Postgres.storage_down(database)
      :ok = Postgres.storage_up(database)

      store = Store.Ecto.new(url: url)
      start_supervised!({Wardrik.Store, store})
      %{store: store, url: url}
    end

    test "migrates its own table before it keeps anything, once", %{store: store, url: url} do
      assert {:ok, _vsn} = Wardrik.Store.put(store, "a", 1)
      assert Repo.migrate() == :ignore

      assert %{rows: [[2]]} =
               SQL.query!(
                 Repo,
                 "SELECT count(*) FROM wardrik_store_migrations"
               )

      refute inspect(store) =~ url
    end

    test "connects over TLS where the url says so" do
      assert [{:verify, :verify_peer} | _rest] =
               Repo.options("postgres://u:p@db.example.com/w?ssl=true")[:ssl]

      assert Repo.options("postgres://u:p@db.example.com/w?ssl=true&x=1")[:url] ==
               "postgres://u:p@db.example.com/w?x=1"

      options = Repo.options("postgres://u:p@localhost/w")
      refute Keyword.has_key?(options, :ssl)
    end

    test "takes a repo or a url, not both" do
      assert_raise ArgumentError, fn -> Store.Ecto.new(repo: R, url: "postgres://x") end
      assert_raise ArgumentError, fn -> Store.Ecto.new([]) end
    end
  end
end
