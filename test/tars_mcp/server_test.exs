defmodule TarsMCP.ServerTest do
  use ExUnit.Case, async: false

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

  describe "what a command sees of the node's environment" do
    setup do
      name = "TARS_SERVER_TEST_#{System.unique_integer([:positive])}"
      System.put_env(name, "secret")
      on_exit(fn -> System.delete_env(name) end)
      %{name: name}
    end

    defp unset(%Server{transport: {:stdio, opts}}) do
      opts[:args]
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        ["-u", name] -> [name]
        _ -> []
      end)
    end

    test "runs the command under env, dropping what it does not keep", %{name: name} do
      server = server(transport: {:stdio, command: "npx", args: ["-y", "x"]})
      {:stdio, opts} = server.transport

      assert Path.basename(opts[:command]) == "env"
      assert Enum.take(opts[:args], -3) == ["npx", "-y", "x"]
      assert name in unset(server)
      refute "PATH" in unset(server)
      refute "HOME" in unset(server)
    end

    test "keeps what the transport sets and the credential variable", %{name: name} do
      server =
        server(
          transport: {:stdio, command: "npx", env: %{name => "given"}},
          credential_env: "GITHUB_TOKEN"
        )

      refute name in unset(server)
      refute "GITHUB_TOKEN" in unset(server)
    end

    test "keeps what :inherit_env names", %{name: name} do
      refute name in unset(server(inherit_env: [name]))
    end

    test "keeps PATH without a release's own directories" do
      release = Path.join(System.tmp_dir!(), "release-#{System.unique_integer([:positive])}")
      path = System.get_env("PATH")
      System.put_env("RELEASE_ROOT", release)

      System.put_env(
        "PATH",
        "#{release}/erts-16/bin:#{release}/bin:/usr/bin:#{release}-other/bin"
      )

      on_exit(fn ->
        System.delete_env("RELEASE_ROOT")
        System.put_env("PATH", path)
      end)

      {:stdio, opts} = server().transport

      assert opts[:env]["PATH"] == "/usr/bin:#{release}-other/bin"
    end

    test "leaves PATH to the port where the node is not a release" do
      refute System.get_env("RELEASE_ROOT")

      {:stdio, opts} = server().transport

      refute Map.has_key?(opts[:env], "PATH")
    end

    test "a PATH the transport sets is its own" do
      {:stdio, opts} =
        server(transport: {:stdio, command: "true", env: %{"PATH" => "/opt/x"}}).transport

      assert opts[:env]["PATH"] == "/opt/x"
    end

    test "is left alone under :inherit_env :all" do
      assert {:stdio, opts} = server(inherit_env: :all).transport
      assert opts[:command] == "true"
    end

    test "the variables it drops are not set in the command", %{name: name} do
      server = server(transport: {:stdio, command: "sh", args: ["-c", "echo ${#{name}:-unset}"]})
      {:stdio, opts} = server.transport

      assert {"unset\n", 0} = System.cmd(opts[:command], opts[:args])
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
