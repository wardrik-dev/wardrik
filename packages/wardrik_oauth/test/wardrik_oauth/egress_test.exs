defmodule WardrikOAuth.EgressTest do
  use WardrikOAuth.Test.Case, async: false

  alias WardrikOAuth.Egress

  setup do
    configure(providers: [])
  end

  describe "check/2" do
    test "takes https under either trust" do
      assert :ok = Egress.check("https://auth.example.com/token", :discovered)
      assert :ok = Egress.check("https://auth.example.com/token", :operator)
    end

    test "takes http only to loopback, and only where the deployment named it" do
      for url <- ["http://localhost:8080/mcp", "http://127.0.0.1/mcp", "http://[::1]:9000/mcp"] do
        assert :ok = Egress.check(url, :operator)
        assert {:error, {:insecure_url, ^url}} = Egress.check(url, :discovered)
      end

      assert {:error, {:insecure_url, _url}} = Egress.check("http://auth.example.com", :operator)
    end

    test "refuses any other scheme, so a server cannot have a program launched" do
      for url <- [
            "vscode://file/etc/passwd",
            "smb://attacker/share",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "https:///no-host"
          ] do
        assert {:error, {:insecure_url, ^url}} = Egress.check(url, :operator)
      end
    end
  end

  describe "options/3" do
    test "pins a discovered URL to the public address it checked, keeping the name for TLS" do
      assert {:ok, options} =
               Egress.options("https://auth.example.com:8443/token?x=1", :discovered,
                 req_options: [form: %{}],
                 resolve: oauth().resolve
               )

      assert options[:url] == "https://93.184.215.14:8443/token?x=1"
      assert options[:connect_options][:hostname] == "auth.example.com"
      assert options[:redirect] == false
      assert options[:receive_timeout] == 15_000
      assert options[:form] == %{}
    end

    test "refuses a discovered host with any address that is not public" do
      for host <- ["internal.example.com", "metadata.example.com", "mixed.example.com"] do
        assert {:error, {:private_address, ^host}} =
                 Egress.options("https://#{host}/token", :discovered, resolve: oauth().resolve)
      end
    end

    test "sends a URL the deployment named where it points, private or not" do
      assert {:ok, options} = Egress.options("https://internal.example.com/token", :operator)
      assert options[:url] == "https://internal.example.com/token"
      refute Keyword.has_key?(options, :connect_options)
      assert options[:redirect] == false
    end
  end

  test "resolve/1 answers a host's addresses" do
    assert {:ok, [{127, 0, 0, 1}]} = Egress.resolve("127.0.0.1")
    assert {:error, :nxdomain} = Egress.resolve("no-such-host.invalid")
  end

  test "public?/1 knows the addresses that are not" do
    private = [
      {0, 0, 0, 0},
      {10, 1, 2, 3},
      {100, 64, 0, 1},
      {127, 0, 0, 1},
      {169, 254, 169, 254},
      {172, 16, 0, 1},
      {172, 31, 255, 255},
      {192, 0, 0, 1},
      {192, 0, 2, 1},
      {192, 168, 1, 1},
      {198, 18, 0, 1},
      {198, 51, 100, 7},
      {203, 0, 113, 7},
      {224, 0, 0, 1},
      {255, 255, 255, 255},
      {0, 0, 0, 0, 0, 0, 0, 0},
      {0, 0, 0, 0, 0, 0, 0, 1},
      {0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254},
      {0xFE80, 0, 0, 0, 0, 0, 0, 1},
      {0xFF02, 0, 0, 0, 0, 0, 0, 1},
      # IPv4-mapped, NAT64 and 6to4 addresses wrapping private ones
      {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001},
      {0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0xA9FE},
      {0x2002, 0xC0A8, 0x0101, 0, 0, 0, 0, 1},
      {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
    ]

    public = [
      {93, 184, 215, 14},
      {8, 8, 8, 8},
      {172, 32, 0, 1},
      {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111},
      {0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD70E}
    ]

    for address <- private, do: refute(Egress.public?(address), inspect(address))
    for address <- public, do: assert(Egress.public?(address), inspect(address))
  end
end
