defmodule TarsMCP.ServerTest do
  use ExUnit.Case, async: true

  alias TarsMCP.Server

  defp server(opts \\ []) do
    Server.new(:github, Keyword.put_new(opts, :transport, {:stdio, command: "true"}))
  end

  describe "new/2" do
    test "names itself after its ref, and takes the defaults" do
      assert %Server{ref: :github, prefix: "github", only: nil, except: []} = server()
    end

    test "takes a prefix of its own" do
      assert server(prefix: "gh").prefix == "gh"
    end

    test "rejects a transport it cannot start" do
      assert_raise ArgumentError, ~r/expected :transport/, fn ->
        Server.new(:github, transport: "https://example.com")
      end
    end

    test "rejects an option it does not have" do
      assert_raise KeyError, fn -> server(retries: 3) end
    end
  end

  describe "an HTTP server's URL" do
    defp http(url, opts \\ []) do
      Server.new(:linear, transport: {:streamable_http, [base_url: url] ++ opts})
    end

    test "is split so the path is not appended to twice" do
      assert {:streamable_http, opts} = http("https://mcp.linear.app/mcp").transport

      assert opts[:base_url] == "https://mcp.linear.app"
      assert opts[:mcp_path] == "/mcp"
    end

    test "is left alone when it carries no path of its own" do
      assert {:streamable_http, opts} = http("https://mcp.linear.app").transport

      assert opts[:base_url] == "https://mcp.linear.app"
      refute Keyword.has_key?(opts, :mcp_path)
    end

    test "keeps a deeper path whole" do
      assert {:streamable_http, opts} = http("https://api.githubcopilot.com/mcp/").transport

      assert opts[:base_url] == "https://api.githubcopilot.com"
      assert opts[:mcp_path] == "/mcp/"
    end

    test "a path stated outright wins" do
      assert {:streamable_http, opts} =
               http("https://mcp.linear.app/mcp", mcp_path: "").transport

      assert opts[:base_url] == "https://mcp.linear.app/mcp"
      assert opts[:mcp_path] == ""
    end

    test "says whether it needs a connection pool" do
      assert Server.http?(http("https://mcp.linear.app/mcp"))
      refute Server.http?(server())
    end
  end

  describe "offers?/2" do
    test "every tool, when nothing is said" do
      assert Server.offers?(server(), "create_issue")
    end

    test "only what :only names" do
      only = server(only: ~w(create_issue))

      assert Server.offers?(only, "create_issue")
      refute Server.offers?(only, "delete_repo")
    end

    test "nothing :except names" do
      except = server(except: ~w(delete_repo))

      assert Server.offers?(except, "create_issue")
      refute Server.offers?(except, "delete_repo")
    end

    test ":except wins over :only" do
      refute Server.offers?(server(only: ~w(delete_repo), except: ~w(delete_repo)), "delete_repo")
    end
  end

  describe "local_name/2" do
    test "joins the prefix and the remote name" do
      assert Server.local_name(server(), "create_issue") == "github__create_issue"
    end

    test "replaces what a tool name may not hold" do
      assert Server.local_name(server(prefix: "my.server"), "create issue") ==
               "my_server__create_issue"
    end

    test "cuts a name to the 64 characters a provider takes" do
      name = Server.local_name(server(), String.duplicate("a", 100))

      assert String.length(name) == 64
      assert ReqLLM.Tool.valid_name?(name)
    end
  end
end
