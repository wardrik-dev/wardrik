defmodule Wardrik.EgressTest do
  use ExUnit.Case, async: false

  import Wardrik.Test.Wardrik

  alias Wardrik.Egress

  test "reaches https at public addresses alone" do
    assert :ok = Egress.public("https://1.1.1.1/mcp")
    assert :ok = Egress.public("https://[2606:4700:4700::1111]/mcp")

    assert {:error, "http://1.1.1.1/mcp isn't an https URL"} = Egress.public("http://1.1.1.1/mcp")
    assert {:error, "file:///etc/passwd isn't an https URL"} = Egress.public("file:///etc/passwd")
  end

  test "refuses loopback, private, link-local and reserved addresses" do
    for host <- ~w(127.0.0.1 10.1.2.3 172.20.0.1 192.168.1.1 169.254.169.254 100.64.0.1 0.0.0.0
                   224.0.0.1 [::1] [::] [fd00::1] [fe80::1] [::ffff:10.0.0.1] [64:ff9b::7f00:1]
                   [2002:a00:1::]) do
      said = String.replace(host, ["[", "]"], "")
      assert {:error, "#{said} is a private address"} == Egress.public("https://#{host}/mcp")
    end
  end

  test "reaches anything for a Wardrik whose operator alone names URLs" do
    assert :ok = Egress.any("http://localhost:4000/mcp")
  end

  test "refuses a host that resolves to a private address, or nowhere" do
    assert {:error, "localhost is at " <> _address} = Egress.public("https://localhost/mcp")
    assert {:error, "nowhere.invalid doesn't resolve"} = Egress.public("https://nowhere.invalid/")
  end

  test "an owner can't add a server at a private address", context do
    wardrik = Wardrik.new(name: :"wardrik #{context.test}")
    start_supervised!({Wardrik, wardrik})

    server = %{
      "owner" => "acme",
      "name" => "internal",
      "url" => "https://169.254.169.254/mcp",
      "auth" => %{"none" => %{}}
    }

    assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
             Wardrik.run(owner(wardrik), "mcp_servers.add", server)

    assert message == "The server can't be reached: 169.254.169.254 is a private address."
  end
end
