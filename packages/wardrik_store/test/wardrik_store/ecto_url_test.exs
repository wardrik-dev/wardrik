if System.get_env("DATABASE_URL") do
  defmodule WardrikStore.EctoURLTest do
    use ExUnit.Case, async: false
    use WardrikStore.Conformance

    alias Ecto.Adapters.Postgres
    alias Ecto.Adapters.SQL
    alias WardrikStore.Ecto.Repo

    setup_all do
      url =
        String.replace(
          System.fetch_env!("DATABASE_URL"),
          ~r{/[^/?]+(\?|$)},
          "/wardrik_store_url\\1",
          global: false
        )

      database = Ecto.Repo.Supervisor.parse_url(url)
      _dropped = Postgres.storage_down(database)
      :ok = Postgres.storage_up(database)

      store = WardrikStore.Ecto.new(url: url)
      start_supervised!({WardrikStore, store})
      %{store: store, url: url}
    end

    test "migrates its own table before it keeps anything, once", %{store: store, url: url} do
      assert {:ok, _vsn} = WardrikStore.put(store, "a", 1)
      assert Repo.migrate() == :ignore

      assert %{rows: [[1]]} =
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

      refute Keyword.has_key?(Repo.options("postgres://u:p@localhost/w"), :ssl)
    end

    test "takes a repo or a url, not both" do
      assert_raise ArgumentError, fn -> WardrikStore.Ecto.new(repo: R, url: "postgres://x") end
      assert_raise ArgumentError, fn -> WardrikStore.Ecto.new([]) end
    end
  end
end
