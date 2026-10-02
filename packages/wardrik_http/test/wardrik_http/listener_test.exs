defmodule WardrikHTTP.ListenerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias WardrikHTTP.Listener

  defp name, do: :"listener-#{System.unique_integer([:positive])}"

  test "serves the API on any free port, and says which" do
    listener = name()
    start_supervised!({Listener, name: listener, port: 0})

    assert {:ok, port} = Listener.port(listener)
    assert {:ok, %{status: 401}} = Req.get("http://127.0.0.1:#{port}/v1/agents", retry: false)
  end

  test "a port another process holds leaves the API unserved until it is free, then serves it" do
    {:ok, held} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(held)
    listener = name()

    log =
      capture_log(fn ->
        start_supervised!({Listener, name: listener, port: port, retry: :timer.hours(1)})
        assert :error = Listener.port(listener)

        :ok = :gen_tcp.close(held)
        send(listener, :listen)

        assert {:ok, ^port} = Listener.port(listener)
      end)

    assert log =~ "The HTTP API could not listen on 127.0.0.1:#{port}"
  end
end
