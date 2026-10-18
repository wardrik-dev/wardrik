defmodule WardrikEcto.ConnectionTest do
  use ExUnit.Case, async: true

  alias WardrikEcto.Connection
  alias WardrikEcto.Test.Services

  @tag :postgres
  test "answers the rows a query finds, over one connection" do
    config = Ecto.Repo.Supervisor.parse_url(Services.database_url())

    assert Connection.query(config, "SELECT 1, NULL") == {:ok, [["1", nil]]}
    assert {:error, %Postgrex.Error{}} = Connection.query(config, "SELECT nothing")
  end

  test "says why it could not connect" do
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)

    assert {:error, %DBConnection.ConnectionError{message: message}} =
             Connection.query([hostname: "127.0.0.1", port: port, database: "w"], "SELECT 1")

    assert message =~ "connection refused"
  end

  test "gives up on a server that never answers" do
    {:ok, listener} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listener)

    assert Connection.query([hostname: "127.0.0.1", port: port, database: "w"], "SELECT 1", 100) ==
             {:error, "no answer within 100ms"}

    :gen_tcp.close(listener)
  end
end
