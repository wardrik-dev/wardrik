defmodule WardrikACP.RPCTest do
  use ExUnit.Case, async: true

  alias WardrikACP.RPC

  test "splits messages at line feeds, and keeps a partial line" do
    buffer =
      IO.iodata_to_binary([
        RPC.request(1, "session/request_permission", %{"a" => 1}),
        RPC.notification("session/update", %{"b" => 2}),
        ~s({"jsonrpc":"2.0","id":2,"result":null}\n),
        ~s({"jsonrpc":"2.0","id":3,"error":{"code":-1,"message":"No."}}\n),
        "not json\n",
        "[1, 2]\n",
        ~s({"jsonrpc":"2.0"}\n),
        ~s({"jsonrpc":"2.0","id":4,)
      ])

    assert RPC.split(buffer) ==
             {[
                {:request, 1, "session/request_permission", %{"a" => 1}},
                {:notification, "session/update", %{"b" => 2}},
                {:result, 2, nil},
                {:error, 3, %{"code" => -1, "message" => "No."}}
              ], ~s({"jsonrpc":"2.0","id":4,)}
  end

  test "encodes an error answering a request" do
    assert RPC.error(7, -32_601, "Method not found: x") |> IO.iodata_to_binary() |> JSON.decode!() ==
             %{
               "jsonrpc" => "2.0",
               "id" => 7,
               "error" => %{"code" => -32_601, "message" => "Method not found: x"}
             }
  end
end
