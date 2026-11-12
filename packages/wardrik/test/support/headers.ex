defmodule Wardrik.Test.Headers do
  @moduledoc """
  An MCP server that's down, and tells the test the authorization each request was sent, by path.

      url = Wardrik.Test.Headers.start("/mcp")
      assert_receive {:authorization, "/mcp", ["Bearer key"]}
  """
  @behaviour Plug

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  @doc "Starts it for the calling test, returning the URL of `path`."
  @spec start(String.t()) :: String.t()
  def start(path) do
    server =
      start_supervised!({Bandit, plug: {__MODULE__, self()}, ip: :loopback, port: 0},
        id: {__MODULE__, path}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://localhost:#{port}" <> path
  end

  @impl Plug
  def init(test), do: test

  @impl Plug
  def call(conn, test) do
    authorization = Plug.Conn.get_req_header(conn, "authorization")
    send(test, {:authorization, conn.request_path, authorization})
    Plug.Conn.send_resp(conn, 503, "")
  end
end
