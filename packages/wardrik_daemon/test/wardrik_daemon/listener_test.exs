defmodule WardrikDaemon.ListenerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import WardrikDaemon.Test, only: [free_port: 0]

  defmodule Hello do
    @moduledoc false
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "hello")
  end

  test "takes the port over once the node holding it lets it go" do
    port = free_port()
    {:ok, held} = :gen_tcp.listen(port, ip: {127, 0, 0, 1}, reuseaddr: true)
    bandit = [plug: Hello, port: port, ip: {127, 0, 0, 1}]

    # It tries once as it starts, then once a minute; the test asks for the next try itself.
    {listener, log} =
      with_log(fn ->
        start_supervised!({WardrikDaemon.Listener, bandit: bandit, retry: 60_000})
      end)

    assert log =~ "Another node holds port #{port}"
    assert {:error, _refused} = get(port)

    :ok = :gen_tcp.close(held)
    send(listener, :listen)
    _state = :sys.get_state(listener)

    assert {:ok, %{status: 200, body: "hello"}} = get(port)
  end

  defp get(port), do: Req.get("http://127.0.0.1:#{port}/", retry: false)
end
