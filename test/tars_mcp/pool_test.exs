defmodule TarsMCP.PoolTest do
  use ExUnit.Case, async: false

  test "an HTTP server gets the connection pool Anubis expects but does not start" do
    refute Process.whereis(Anubis.Finch)

    start_supervised!(
      {TarsMCP.Supervisor,
       servers: [remote: [transport: {:streamable_http, base_url: "http://127.0.0.1:1/mcp"}]]}
    )

    assert Process.whereis(Anubis.Finch)
  end

  test "a deployment of commands runs no pool" do
    start_supervised!(
      {TarsMCP.Supervisor, servers: [local: [transport: {:stdio, command: "true"}]]}
    )

    refute Process.whereis(Anubis.Finch)
  end
end
