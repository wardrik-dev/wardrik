defmodule WardrikMCP.PoolTest do
  use ExUnit.Case, async: false

  # Neither server here can be reached, so each test waits for its connection
  # to report that and settle into retrying before the test ends.
  setup do
    test = self()

    :ok =
      :telemetry.attach(
        {__MODULE__, test},
        [:wardrik_mcp, :connection, :retrying],
        fn _event, _measurements, %{key: key}, _config -> send(test, {:retrying, key}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach({__MODULE__, test}) end)
  end

  test "an HTTP server gets the connection pool Anubis expects but does not start" do
    refute Process.whereis(Anubis.Finch)

    start_supervised!(
      {WardrikMCP.Supervisor,
       servers: [remote: [transport: {:streamable_http, base_url: "http://127.0.0.1:1/mcp"}]]}
    )

    assert Process.whereis(Anubis.Finch)
    assert_receive {:retrying, %Wardrik.Resource{name: "deployment/server/remote"}}, 5_000
  end

  test "a deployment of commands runs no pool" do
    start_supervised!(
      {WardrikMCP.Supervisor, servers: [local: [transport: {:stdio, command: "true"}]]}
    )

    refute Process.whereis(Anubis.Finch)
    assert_receive {:retrying, %Wardrik.Resource{name: "deployment/server/local"}}, 5_000
  end
end
