defmodule WardrikMCP.ConfigTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Resource

  defp server(yaml) do
    {:ok, %{"mcp" => section}} = YamlElixir.read_from_string("mcp:\n" <> yaml)
    {:ok, servers: [{_name, server}]} = WardrikMCP.config(section)
    server
  end

  defp refused(yaml) do
    {:ok, %{"mcp" => section}} = YamlElixir.read_from_string("mcp:\n" <> yaml)
    {:error, path, message} = WardrikMCP.config(section)
    Enum.join(path, ".") <> " " <> message
  end

  describe "attach/2" do
    test "registers each server by its name, the servers owners add, and the supervisor" do
      store = Wardrik.Test.store()

      host =
        WardrikMCP.attach(Wardrik.Host.new(store: store),
          servers: [
            notes: [transport: {:stdio, command: "true"}, serves: [Resource.parse!("acme/*")]]
          ],
          stderr: :discard
        )

      assert %{"servers" => WardrikMCP.Added, "notes" => notes} = Wardrik.Host.sources(host)
      assert notes.key == Resource.parse!("deployment/server/notes")
      assert notes.stderr == :discard

      assert [{WardrikMCP.Supervisor, opts}] = Wardrik.Host.children(host)
      assert opts[:store] == store
      assert [notes: _server] = opts[:servers]

      assert WardrikDefinition.Source.spec(notes, AgentID.parse!("acme/triage")) ==
               {:ok, {WardrikMCP, notes.key}}

      assert WardrikDefinition.Source.spec(notes, AgentID.parse!("globex/triage")) ==
               {:error, "notes serves acme/*, and not globex/triage"}

      assert_raise ArgumentError, fn -> WardrikMCP.attach(Wardrik.Host.new(), servrs: []) end
    end

    test "reads a server named by its url or command as config.yaml's" do
      host =
        WardrikMCP.attach(Wardrik.Host.new(store: Wardrik.Test.store()),
          servers: [
            github: [url: "https://api.githubcopilot.com/mcp/", credential: "github", timeout: 5],
            notes: [command: "notes-mcp", args: ["--quiet"]]
          ]
        )

      assert %{"github" => github, "notes" => notes} = Wardrik.Host.sources(host)

      assert {:streamable_http, [mcp_path: "/mcp/", base_url: "https://api.githubcopilot.com"]} =
               github.transport

      assert github.credential == "github"
      assert github.timeout == 5_000
      assert {:stdio, stdio} = notes.transport
      assert Enum.take(stdio[:args], -2) == ["notes-mcp", "--quiet"]

      assert_raise ArgumentError, ~r/the MCP server docs has both command and url/, fn ->
        WardrikMCP.attach(Wardrik.Host.new(),
          servers: [docs: [url: "https://docs.example.com/mcp", command: "docs-mcp"]]
        )
      end
    end

    test "registers the servers people add as what they may sign in to" do
      store = Wardrik.Test.store()
      host = WardrikMCP.attach(Wardrik.Host.new(store: store))

      assert Wardrik.Host.sign_ins(host) == %{
               "servers" => %WardrikMCP.Servers.Providers{store: store}
             }

      # A host built without `use Wardrik` offers the servers it wires itself.
      assert Wardrik.Host.servers(host) == %Wardrik.Servers.None{}
    end
  end

  describe "config/1" do
    test "reads no section as no servers" do
      assert WardrikMCP.config(nil) == {:ok, servers: []}
      assert WardrikMCP.config("x") == {:error, [], "is a set of keys"}
    end

    test "a server with a command is started as one" do
      server =
        server("""
          notes:
            command: npx
            args: [-y, server-filesystem]
            env:
              ROOT: /srv/notes
            only: [read_file]
            timeout: 30
        """)

      assert server[:transport] ==
               {:stdio,
                command: "npx", args: ["-y", "server-filesystem"], env: %{"ROOT" => "/srv/notes"}}

      assert server[:only] == ["read_file"]
      assert server[:timeout] == 30_000
    end

    test "a server with a url is reached over HTTP, with the credential it names" do
      server =
        server("""
          github:
            url: https://api.githubcopilot.com/mcp/
            headers:
              x-team: core
            credential: github
        """)

      assert server[:transport] ==
               {:streamable_http,
                base_url: "https://api.githubcopilot.com/mcp/", headers: %{"x-team" => "core"}}

      assert server[:credential] == "github"
    end

    test "a server gates the tools it names, and may be trusted" do
      github = server("  github:\n    url: https://x\n    gated: [create_*, issue_write]\n")
      assert github[:gated] == ["create_*", "issue_write"]
      refute Keyword.has_key?(github, :trusted)

      notes = server("  notes:\n    command: npx\n    gated: true\n    trusted: true\n")
      assert {notes[:gated], notes[:trusted]} == {true, true}
      assert server("  docs:\n    command: npx\n    gated: false\n")[:gated] == false
    end

    test "says where a server does not read" do
      for {yaml, message} <- [
            {"  notes:\n    command: npx\n    comand: typo\n", "notes.comand is not a setting"},
            {"  x: {url: https://a.example.com/mcp, org: globex}\n", "x.org is not a setting"},
            {"  a:\n    command: x\n    url: https://x\n", "a has both command and url"},
            {"  b:\n    only: [x]\n", "b needs a command or a url"},
            {"  c:\n", "c needs a command or a url"},
            {"  d: [x]\n", "d is a set of keys"},
            {"  workers:\n    command: npx\n",
             "workers names its tools with workers, which tool workers' tools are named with"},
            {"  notes:\n    command: npx\n    prefix: workers\n",
             "notes names its tools with workers"},
            {"  my__notes:\n    command: npx\n", "my__notes names its tools with my__notes"},
            {"  notes:\n    command: npx\n    prefix: my__notes\n",
             "notes names its tools with my__notes"},
            {"  notes:\n    command: npx\n    prefix: 1\n", "notes names its tools with 1"},
            {"  a:\n    command: x\n    timeout: soon\n",
             "a.timeout is a whole number of seconds"},
            {"  a:\n    command: x\n    gated: [1]\n",
             "a.gated is true, false, or a list of the server's tool names"},
            {"  a:\n    command: x\n    trusted: 1\n", "a.trusted is true or false"},
            {"  a:\n    url: https://x\n    credential: 1\n",
             "a.credential is the name of a credential"}
          ] do
        assert refused(yaml) =~ message
      end

      for credential <- ["user:github", "a/b", "_x", "\"\""] do
        assert refused("  a:\n    url: https://x\n    credential: #{credential}\n") =~
                 "a.credential is"
      end
    end
  end
end
