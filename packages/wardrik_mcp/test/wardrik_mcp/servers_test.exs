defmodule WardrikMCP.ServersTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Credential
  alias Wardrik.Error
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Scope
  alias Wardrik.Servers.Key
  alias Wardrik.Servers.Server
  alias WardrikMCP.Auth
  alias WardrikMCP.Connection
  alias WardrikMCP.Listing
  alias WardrikMCP.Remote

  # An MCP server over Streamable HTTP, answering each request with JSON: one
  # tool marked read-only, one not, and a 401 to any request without the
  # header the test asks for.
  defmodule Stub do
    @moduledoc false
    use Plug.Router, copy_opts_to_assign: :expected

    plug(Plug.Parsers, parsers: [:json], json_decoder: JSON)
    plug(:match)
    plug(:dispatch)

    @tools [
      %{
        "name" => "echo",
        "annotations" => %{"readOnlyHint" => true},
        "description" => "Hands the value back.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}}
        }
      },
      %{
        "name" => "post",
        "description" => "Posts the value.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "string"}}
        }
      }
    ]

    post "/mcp" do
      if conn.assigns.expected[:authorization] in [nil | get_req_header(conn, "authorization")],
        do: answer(conn, conn.body_params),
        else: send_resp(conn, 401, "")
    end

    match(_, do: send_resp(conn, 405, ""))

    defp answer(conn, %{"id" => id, "method" => method} = message) do
      body = %{"jsonrpc" => "2.0", "id" => id, "result" => result(method, message["params"])}

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(body))
    end

    defp answer(conn, _notification), do: send_resp(conn, 202, "")

    defp result("initialize", params),
      do: %{
        "protocolVersion" => params["protocolVersion"],
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "stub", "version" => "1"}
      }

    defp result("tools/list", _params), do: %{"tools" => @tools}

    defp result("tools/call", %{"name" => name, "arguments" => arguments}),
      do: %{"content" => [%{"type" => "text", "text" => "#{name}: #{arguments["value"]}"}]}

    defp result(_method, _params), do: %{}
  end

  # Resolves stub-key for an org that holds one, as a vault would.
  defmodule Vault do
    @moduledoc false
    defstruct []

    def resolve("stub-key", %Wardrik.Call{scope: scope}) do
      %AgentID{org: org} = Scope.agent_id(scope)
      {:ok, Credential.secret("key-for-#{org}", owner: org)}
    end
  end

  defimpl Wardrik.Credentials, for: Vault do
    def resolve(_vault, name, call), do: Vault.resolve(name, call)
    def refused(_vault, _name, _call), do: :ok
    def key(_vault, _name), do: :error
  end

  @key WardrikVault.generate_key()
  @reachable &__MODULE__.reachable/1

  def reachable(_url), do: :ok

  setup do
    start_supervised!({WardrikMCP.Supervisor, store: Wardrik.Test.store(), check: @reachable})

    org = "o#{System.unique_integer([:positive])}"
    owner = Prefix.new!(org: org)
    %{key: Key.new(owner, "crm"), name: "crm", org: org, owner: owner}
  end

  # Serves the stub, asking for `authorization` where it is given one.
  defp serve(expected) do
    bandit = start_supervised!({Bandit, plug: {Stub, expected}, port: 0, ip: :loopback})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    "http://127.0.0.1:#{port}/mcp"
  end

  defp servers do
    store = Wardrik.Test.store()
    oauth = oauth(store)
    vault = WardrikVault.new(store: store, keys: [@key], grants: oauth)
    %WardrikMCP.Servers{store: store, oauth: oauth, vault: vault, check: @reachable}
  end

  # Sign-ins discovered at a stub that answers no metadata, with the servers
  # owners added as providers, and a configured one named taken.
  defp oauth(store) do
    WardrikOAuth.new(
      added: %WardrikMCP.Servers.Providers{store: store},
      providers: [taken: [resource: "https://taken.example/mcp"]],
      redirect: [url: "https://wardrik.example/oauth", open: false],
      req_options: [plug: &__MODULE__.no_metadata/1]
    )
  end

  def no_metadata(conn), do: Plug.Conn.send_resp(conn, 404, "")

  # An authorization server that publishes its metadata, at an issuer a host
  # names, behind a resource that publishes none.
  def issuer_metadata(
        %{host: "issuer.example", request_path: "/.well-known/oauth-authorization-server"} = conn
      ),
      do:
        Req.Test.json(conn, %{
          issuer: "https://issuer.example",
          authorization_endpoint: "https://issuer.example/authorize",
          token_endpoint: "https://issuer.example/token",
          code_challenge_methods_supported: ["S256"]
        })

  def issuer_metadata(conn), do: Plug.Conn.send_resp(conn, 404, "")

  # A host's providers: the servers owners add, each with the owner's own
  # client and issuer.
  defmodule OwnClient do
    @moduledoc false
    defstruct [:store]

    defimpl WardrikOAuth.Providers do
      def fetch(%{store: store}, name, opts) do
        with {:ok, provider} <-
               WardrikOAuth.Providers.fetch(
                 %WardrikMCP.Servers.Providers{store: store},
                 name,
                 opts
               ),
             do: {:ok, %{provider | issuer: "https://issuer.example", client_id: "own-client"}}
      end

      def names(%{store: store}),
        do: WardrikOAuth.Providers.names(%WardrikMCP.Servers.Providers{store: store})
    end
  end

  defp keep(%{key: key}, url, auth) do
    :ok = Remote.put(Wardrik.Test.store(), %Remote{key: key, url: url, auth: auth, filters: []})
  end

  defp scope(key, org) do
    Config.new(tools: [{WardrikMCP, key}])
    |> Scope.root(AgentID.new!("assistant", org: org),
      host: Wardrik.Test.host(credentials: %Vault{})
    )
  end

  defp run(key, org, tool, arguments) do
    call = %{id: "call_1", name: "#{key.name}__#{tool}", arguments: arguments}
    [message] = ToolRunner.messages([ToolRunner.execute(call, scope(key, org))])
    [part] = message.content
    part.text
  end

  # Asking for its tools starts the server's connection here; they are what
  # it offers once that connection has listed them.
  defp listed(key) do
    WardrikMCP.tools(key)
    {:ok, tools} = Connection.await(key)
    Enum.map(tools, & &1.name)
  end

  describe "adding" do
    test "keeps a server an owner adds, lists it, and removes it", %{name: name, owner: owner} do
      fields = %{
        "url" => "https://mcp.example.com/mcp",
        "auth" => %{"secret" => %{"name" => "k"}}
      }

      assert {:ok, :connected} =
               Wardrik.Servers.add(servers(), owner, name: name, fields: fields, by: nil)

      assert [
               %Server{
                 name: ^name,
                 url: "https://mcp.example.com/mcp",
                 auth: "secret",
                 secret: "k"
               }
             ] = Wardrik.Servers.list(servers(), owner)

      assert Wardrik.Servers.list(servers(), Prefix.new!(org: "acme", user: "jon")) == []

      assert {:error, %Error{type: :conflict}} =
               Wardrik.Servers.add(servers(), owner, name: name, fields: fields, by: nil)

      assert :ok = Wardrik.Servers.remove(servers(), owner, name: name, by: nil)
      assert Wardrik.Servers.list(servers(), owner) == []

      assert {:error, %Error{type: :not_found}} =
               Wardrik.Servers.remove(servers(), owner, name: name, by: nil)
    end

    test "starts the sign-in with the provider the host's :added finds for it",
         %{name: name, owner: owner} do
      store = Wardrik.Test.store()

      oauth =
        WardrikOAuth.new(
          added: %OwnClient{store: store},
          redirect: [url: "https://wardrik.example/oauth", open: false],
          req_options: [plug: &__MODULE__.issuer_metadata/1],
          resolve: fn _host -> {:ok, [{93, 184, 216, 34}]} end
        )

      vault = WardrikVault.new(store: store, keys: [@key], grants: oauth)
      servers = %WardrikMCP.Servers{store: store, oauth: oauth, vault: vault, check: @reachable}
      start_supervised!({WardrikOAuth.Supervisor, oauth: oauth, callback: false})

      # The server publishes no metadata of its own; the host names its issuer.
      assert {:ok, %{url: url}} =
               Wardrik.Servers.add(servers, owner,
                 name: name,
                 fields: %{"url" => "https://mcp.example.com/mcp", "auth" => %{"oauth" => %{}}},
                 by: nil
               )

      assert String.starts_with?(url, "https://issuer.example/authorize?")
      assert url =~ "client_id=own-client"
    end

    test "refuses what it cannot keep", %{name: name, owner: owner} do
      add = fn name, fields ->
        Wardrik.Servers.add(servers(), owner, name: name, fields: fields, by: nil)
      end

      none = %{"none" => %{}}

      assert {:error, %Error{type: :invalid, message: message}} =
               add.(name, %{"url" => "http://mcp.example.com/mcp", "auth" => none})

      assert message =~ "not an https URL"

      assert {:error, %Error{message: message}} =
               add.(name, %{"command" => "rm", "url" => "https://x.example", "auth" => none})

      assert message =~ "command is not a server's field"

      assert {:error, %Error{message: message}} =
               add.("a__b", %{"url" => "https://x.example", "auth" => none})

      assert message =~ "not a server's name"

      assert {:error, %Error{message: message}} =
               add.(name, %{
                 "url" => "https://x.example",
                 "auth" => %{"oauth" => %{"scopes" => "write"}}
               })

      assert message =~ "scopes are a list"
    end

    test "refuses the name of an account the deployment offers", %{owner: owner} do
      fields = %{"url" => "https://x.example/mcp", "auth" => %{"none" => %{}}}

      assert {:error, %Error{type: :conflict, message: message}} =
               Wardrik.Servers.add(servers(), owner, name: "taken", fields: fields, by: nil)

      assert message =~ "an account this deployment offers"
    end

    test "refuses a URL its check refuses", %{name: name, owner: owner} do
      servers = %{servers() | check: &Remote.reachable/1}
      fields = %{"url" => "https://127.0.0.1/mcp", "auth" => %{"none" => %{}}}

      assert {:error, %Error{type: :invalid, message: message}} =
               Wardrik.Servers.add(servers, owner, name: name, fields: fields, by: nil)

      assert message =~ "cannot be reached from here"
    end
  end

  describe "a server that takes no credential" do
    setup context do
      keep(context, serve([]), %Auth.None{})
      :ok
    end

    test "starts its connection the first time its tools are asked for", %{key: key} do
      refute Connection.running?(key, :deployment)
      WardrikMCP.tools(key)

      assert Connection.running?(key, :deployment)
      assert "#{key.name}__echo" in listed(key)
      assert Listing.recall(Wardrik.Test.store(), key) != []
    end

    test "serves its owner's agents and no one else's", %{key: key, org: org} do
      listed(key)

      assert run(key, org, "echo", %{"value" => "hi"}) =~ "echo: hi"
      assert run(key, "globex", "echo", %{"value" => "hi"}) =~ "does not serve globex/assistant"
    end

    test "is not among every server, which names the deployment's own", %{key: key} do
      listed(key)

      refute key in WardrikMCP.servers()
      assert WardrikMCP.tools(:*) == []
    end

    test "waits on a person for a tool not marked read-only", %{key: key} do
      listed(key)

      assert WardrikMCP.annotations(key, "#{key.name}__post").gated
      refute WardrikMCP.annotations(key, "#{key.name}__echo").gated
      assert WardrikMCP.annotations(key, "#{key.name}__echo").labels == ["outside"]
    end

    test "is among the tools of its owner's servers/*, and of no one else's",
         %{key: key, org: org} do
      listed(key)
      agent = AgentID.new!("assistant", org: org)
      jon = AgentID.new!("assistant", org: org, user: "jon")

      assert "#{key.name}__echo" in Enum.map(WardrikMCP.Added.tools(agent), & &1.name)
      assert WardrikMCP.Added.tools(jon) == []
      assert WardrikMCP.Added.tools(AgentID.new!("assistant", org: "globex")) == []
      assert WardrikMCP.Added.annotations(agent, "#{key.name}__post").gated

      assert WardrikMCP.Added.annotations(agent, "gone__post") == %{
               gated: true,
               labels: ["outside"]
             }
    end

    test "is closed everywhere as it is removed", %{key: key} do
      listed(key)
      assert :ok = Wardrik.Servers.remove(servers(), key.owner, name: key.name, by: nil)

      refute Connection.running?(key, :deployment)
      assert WardrikMCP.tools(key) == []
    end
  end

  describe "a server reached with the owner's secret" do
    setup context do
      url = serve(authorization: "Bearer key-for-#{context.org}")

      keep(context, url, %Auth.Secret{name: "stub-key", header: "authorization", scheme: "Bearer"})

      :ok
    end

    test "offers the tool that connects it, then its own once the owner's call lists them",
         %{key: key, org: org} do
      assert ["#{key.name}__connect"] == listed(key)
      assert run(key, org, "connect", %{}) =~ "connected"

      assert Connection.running?(key, {:owner, org})
      assert "#{key.name}__echo" in Enum.map(WardrikMCP.tools(key), & &1.name)
      assert run(key, org, "echo", %{"value" => "hi"}) =~ "echo: hi"
    end
  end
end
