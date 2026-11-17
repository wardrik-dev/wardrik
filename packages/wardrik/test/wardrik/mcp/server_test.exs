defmodule Wardrik.MCP.ServerTest do
  use ExUnit.Case, async: true

  alias Wardrik.Credentials.Endpoint
  alias Wardrik.MCP.Server

  test "sends a credential in a header over HTTP, as its scheme says" do
    http = {:streamable_http, url: "https://mcp.test/mcp", headers: %{"x-app" => "1"}}

    server = Server.new!("a", transport: http, credential_name: "a")
    assert {:streamable_http, opts} = Server.transport(server, "tok")

    assert opts[:headers] == %{"x-app" => "1", "authorization" => "Bearer tok"}

    server =
      Server.new!("a",
        transport: {:streamable_http, url: "https://mcp.test/mcp"},
        credential_name: "a",
        credential_header: "x-key",
        credential_scheme: ""
      )

    assert {:streamable_http, opts} = Server.transport(server, "tok")
    assert opts[:headers] == %{"x-key" => "tok"}
  end

  test "connects where an endpoint credential says, with its headers" do
    server =
      Server.new!("a",
        transport: {:streamable_http, headers: %{"x-app" => "1", "x-key" => "default"}},
        credential_name: "a"
      )

    endpoint = %Endpoint{url: "https://tenant.test/mcp", headers: %{"x-key" => "maria's"}}
    assert {:ok, routed, nil} = Server.apply_credential(server, endpoint)
    assert {:streamable_http, opts} = Server.transport(routed, nil)
    assert opts[:base_url] == "https://tenant.test"
    assert opts[:mcp_path] == "/mcp"
    assert opts[:headers] == %{"x-app" => "1", "x-key" => "maria's"}

    endpoint = %Endpoint{url: "https://tenant.test/mcp", token: "tok"}
    assert {:ok, routed, "tok"} = Server.apply_credential(server, endpoint)
    assert {:streamable_http, opts} = Server.transport(routed, "tok")
    assert opts[:headers]["authorization"] == "Bearer tok"

    assert {:error, "a's credential gives no URL" <> _} = Server.apply_credential(server, "tok")

    assert {:error, "a's credential gives no URL" <> _} =
             Server.apply_credential(server, %Endpoint{headers: %{"x-key" => "k"}})

    assert {:error, "a server over HTTP needs an http or https :url" <> _} =
             Server.apply_credential(server, %Endpoint{url: "ftp://tenant.test"})
  end

  test "needs a url over HTTP, unless its credential gives one" do
    assert_raise ArgumentError, ~r/needs a :url, or a :credential_name/, fn ->
      Server.new!("a", transport: {:streamable_http, headers: %{}})
    end

    server = Server.new!("a", transport: {:streamable_http, url: "https://mcp.test/mcp"})
    assert {:ok, ^server, "tok"} = Server.apply_credential(server, "tok")

    endpoint = %Endpoint{headers: %{"x-key" => "k"}}
    assert {:ok, routed, nil} = Server.apply_credential(server, endpoint)
    assert {:streamable_http, opts} = Server.transport(routed, nil)
    assert opts[:base_url] == "https://mcp.test"
    assert opts[:headers] == %{"x-key" => "k"}
  end

  test "gives a command an endpoint's token, but not a URL" do
    server =
      Server.new!("a",
        transport: {:stdio, command: "x"},
        credential_name: "a",
        credential_env: "A_TOKEN"
      )

    assert {:ok, ^server, "tok"} = Server.apply_credential(server, %Endpoint{token: "tok"})

    assert {:error, "a runs as a command" <> _} =
             Server.apply_credential(server, %Endpoint{url: "https://tenant.test/mcp"})
  end

  test "reaches a server over HTTP through its Wardrik.MCP's own pool" do
    server = %{
      Server.new!("a", transport: {:streamable_http, url: "https://mcp.test/mcp"})
      | mcp: MyApp.MCP
    }

    assert {:streamable_http, opts} = Server.transport(server, nil)
    assert opts[:finch_name] == Wardrik.MCP.Connection.finch(MyApp.MCP)
  end

  test "sends a credential in a variable to a command, where it names one" do
    stdio = {:stdio, command: "server"}

    server = Server.new!("a", transport: stdio, credential_env: "TOKEN")
    assert {:stdio, opts} = Server.transport(server, "tok")
    assert opts[:env] == %{"TOKEN" => "tok"}

    server = Server.new!("a", transport: stdio)
    assert {:stdio, opts} = Server.transport(server, "tok")
    assert opts[:env] == %{}
  end

  test "starts a command through env, unsetting what it isn't given" do
    System.put_env("SERVER_TEST_SENTINEL", "secret")
    on_exit(fn -> System.delete_env("SERVER_TEST_SENTINEL") end)

    stdio = {:stdio, command: "server", args: ["stdio"], env: %{"SERVER_TEST_SENTINEL" => "mine"}}
    server = Server.new!("a", transport: stdio)
    assert {:stdio, opts} = Server.transport(server, nil)

    assert opts[:command] == "env"
    assert ["--", "server", "stdio"] = Enum.take(opts[:args], -3)
    refute "SERVER_TEST_SENTINEL" in opts[:args]
    refute "PATH" in opts[:args]

    server = Server.new!("a", transport: {:stdio, command: "server"})
    assert {:stdio, opts} = Server.transport(server, nil)

    assert "SERVER_TEST_SENTINEL" in opts[:args]
  end

  test "names its tools under its prefix, or its name" do
    github = Server.new!(:github, transport: {:stdio, command: "x"})
    assert Server.prefix(github) == "github"

    gh = Server.new!("gh", transport: {:stdio, command: "x"}, prefix: "github")
    assert Server.prefix(gh) == "github"
  end

  test "refuses a transport it can't start" do
    for transport <- [{:stdio, args: ["stdio"]}, {:stdio, command: "x", cwd: "/"}, {:ssh, []}] do
      assert_raise NimbleOptions.ValidationError, ~r/:transport/, fn ->
        Server.new!("a", transport: transport)
      end
    end
  end

  test "reads the secrets its headers name, and knows which they are" do
    headers = %{"authorization" => ["Bearer ", {:secret, "KEY"}], "x-team" => {:secret, "TEAM"}}

    server = %{
      Server.new!("a",
        transport: {:streamable_http, url: "https://mcp.test/mcp", headers: headers}
      )
      | secret: fn "acme", name -> {:ok, String.downcase(name)} end,
        owner: "acme"
    }

    assert {:ok, %Server{transport: {:streamable_http, opts}}} = Server.resolve_headers(server)
    assert opts[:headers] == %{"authorization" => "Bearer key", "x-team" => "team"}

    assert Server.names?(server, "KEY")
    assert Server.names?(server, "TEAM")
    refute Server.names?(server, "OTHER")
    other = Server.new!("b", transport: {:stdio, command: "x"})
    refute Server.names?(other, "KEY")

    assert_raise NimbleOptions.ValidationError, ~r/:headers/, fn ->
      Server.new!("c",
        transport: {:streamable_http, url: "https://mcp.test/mcp", headers: %{"x" => {:env, "X"}}}
      )
    end
  end
end
