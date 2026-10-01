defmodule WardrikDaemon.ConfigTest do
  use ExUnit.Case, async: false

  alias WardrikDaemon.Config

  @moduletag :tmp_dir

  # Every file names the deployment's org first; what each other test reads
  # is the rest.
  defp read(yaml, context) do
    with {:ok, [{Wardrik.Fleet, _org} | settings]} <- read_all(yaml, context),
         do: {:ok, settings}
  end

  defp read_all(yaml, %{tmp_dir: dir}) do
    file = Path.join(dir, "config.yaml")
    File.write!(file, yaml)
    Config.read(file)
  end

  defp env(value) do
    name = "WARDRIK_CONFIG_TEST_#{System.unique_integer([:positive])}"
    System.put_env(name, value)
    on_exit(fn -> System.delete_env(name) end)
    name
  end

  describe "read/1" do
    test "a missing file configures nothing", %{tmp_dir: dir} do
      assert {:ok, []} = Config.read(Path.join(dir, "config.yaml"))
    end

    test "an empty file configures nothing", context do
      assert {:ok, []} = read("", context)
    end

    test "org is the deployment's org, default unless it says", context do
      assert {:ok, [{Wardrik.Fleet, [org: "default"]}, {WardrikDaemon.SSH, _ssh}]} =
               read_all("ssh: {port: 2223}\n", context)

      assert {:ok, [{Wardrik.Fleet, [org: "acme"]}]} = read_all("org: acme\n", context)

      for org <- ["_acme", "@acme", "a/b"] do
        assert {:error, message} = read_all("org: #{inspect(org)}\n", context)
        assert message =~ "which is not an org"
      end
    end

    test "a server and a target serve the deployment's org, the orgs they name, or every org",
         context do
      yaml = """
      org: acme
      mcp:
        mine: {url: https://a.example.com/mcp}
        theirs: {url: https://b.example.com/mcp, org: globex}
        shared: {url: https://c.example.com/mcp, org: [acme, globex]}
        public: {url: https://d.example.com/mcp, org: "*"}
      notify:
        ops: {webhook: {url: https://hooks.example.com/a}}
        globex: {org: globex, webhook: {url: https://hooks.example.com/b}}
      """

      assert {:ok, settings} = read_all(yaml, context)
      servers = settings[WardrikMCP][:servers]

      assert servers[:mine][:orgs] == ["acme"]
      assert servers[:theirs][:orgs] == ["globex"]
      assert servers[:shared][:orgs] == ["acme", "globex"]
      assert servers[:public][:orgs] == :all

      targets = settings[WardrikNotify][:targets]
      assert {WardrikNotify.Webhook, ops} = targets[:ops]
      assert ops[:orgs] == ["acme"]
      assert {WardrikNotify.Webhook, globex} = targets[:globex]
      assert globex[:orgs] == ["globex"]

      assert {:error, message} =
               read_all("mcp:\n  x: {url: https://a.example.com/mcp, org: [_x]}\n", context)

      assert message =~ "mcp.x.org is an org, a list of them, or * for every org"
    end

    test "a server with a command is started as one", context do
      assert {:ok, [{WardrikMCP, servers: [notes: server]}]} =
               read(
                 """
                 mcp:
                   notes:
                     command: npx
                     args: [-y, server-filesystem]
                     env:
                       ROOT: /srv/notes
                     only: [read_file]
                     timeout: 30
                 """,
                 context
               )

      assert server[:transport] ==
               {:stdio,
                command: "npx", args: ["-y", "server-filesystem"], env: %{"ROOT" => "/srv/notes"}}

      assert server[:only] == ["read_file"]
      assert server[:timeout] == 30_000
    end

    test "a server with a url is reached over HTTP, as the user it names", context do
      assert {:ok, [{WardrikMCP, servers: [github: server]}]} =
               read(
                 """
                 mcp:
                   github:
                     url: https://api.githubcopilot.com/mcp/
                     headers:
                       x-team: core
                     credential: user:github
                 """,
                 context
               )

      assert server[:transport] ==
               {:streamable_http,
                base_url: "https://api.githubcopilot.com/mcp/", headers: %{"x-team" => "core"}}

      assert server[:credential] == {:user, "github"}
    end

    test "${NAME} is read from the environment", context do
      name = env("lin_secret")

      assert {:ok, [{WardrikMCP, servers: [linear: server]}]} =
               read(
                 """
                 mcp:
                   linear:
                     url: https://mcp.linear.app/mcp
                     headers:
                       authorization: Bearer ${#{name}}
                 """,
                 context
               )

      assert {:streamable_http, opts} = server[:transport]
      assert opts[:headers] == %{"authorization" => "Bearer lin_secret"}
    end

    test "oauth and vault settings keep their shape", context do
      key = env("a-vault-key")

      assert {:ok, settings} =
               read(
                 """
                 oauth:
                   client:
                     name: Acme agents
                   providers:
                     github:
                       resource: https://api.githubcopilot.com/mcp/
                       client_id: abc
                       scopes: [repo]
                 vault:
                   keys: ["${#{key}}"]
                 """,
                 context
               )

      oauth = Keyword.fetch!(settings, WardrikOAuth)
      assert oauth[:client] == [name: "Acme agents"]
      assert oauth[:providers][:github][:scopes] == ["repo"]
      assert Keyword.fetch!(settings, WardrikVault) == [keys: ["a-vault-key"]]
    end

    test "a variable that is not set says which value names it", context do
      assert {:error, message} =
               read(~s(vault:\n  keys: ["${WARDRIK_CONFIG_TEST_UNSET}"]\n), context)

      assert message =~ "vault.keys.0 names ${WARDRIK_CONFIG_TEST_UNSET}, which is not set"
    end

    test "a key nothing takes is refused", context do
      assert {:error, message} =
               read("mcp:\n  notes:\n    command: npx\n    comand: typo\n", context)

      assert message =~ "mcp.notes.comand is not a setting"
    end

    test "a server is a command or a url, not both and not neither", context do
      assert {:error, both} = read("mcp:\n  a:\n    command: x\n    url: https://x\n", context)
      assert both =~ "mcp.a has both command and url"

      assert {:error, neither} = read("mcp:\n  b:\n    only: [x]\n", context)
      assert neither =~ "mcp.b needs a command or a url"
    end

    test "a server's tools may not be named for the tool workers", context do
      assert {:error, named} = read("mcp:\n  workers:\n    command: npx\n", context)

      assert named =~
               "mcp.workers names its tools with workers, which tool workers' tools are named with"

      assert {:error, prefixed} =
               read("mcp:\n  notes:\n    command: npx\n    prefix: workers\n", context)

      assert prefixed =~ "mcp.notes names its tools with workers"
    end

    test "a server's name or prefix may not hold __", context do
      assert {:error, named} = read("mcp:\n  my__notes:\n    command: npx\n", context)
      assert named =~ "mcp.my__notes names its tools with my__notes"

      assert {:error, prefixed} =
               read("mcp:\n  notes:\n    command: npx\n    prefix: my__notes\n", context)

      assert prefixed =~ "mcp.notes names its tools with my__notes"
    end

    test "a server gates the tools it names, and may be trusted", context do
      assert {:ok, [{WardrikMCP, servers: [github: github, notes: notes]}]} =
               read(
                 """
                 mcp:
                   github:
                     url: https://api.githubcopilot.com/mcp/
                     gated: [create_*, issue_write]
                   notes:
                     command: npx
                     gated: true
                     trusted: true
                 """,
                 context
               )

      assert github[:gated] == ["create_*", "issue_write"]
      refute Keyword.has_key?(github, :trusted)
      assert notes[:gated] == true
      assert notes[:trusted] == true

      assert {:error, gated} = read("mcp:\n  a:\n    command: x\n    gated: [1]\n", context)
      assert gated =~ "mcp.a.gated is true, or a list of the server's tool names"
      assert {:error, trusted} = read("mcp:\n  a:\n    command: x\n    trusted: 1\n", context)
      assert trusted =~ "mcp.a.trusted is true or false"
    end

    test "a credential is user:, org: or named:", context do
      assert {:error, message} =
               read("mcp:\n  a:\n    url: https://x\n    credential: github\n", context)

      assert message =~ "mcp.a.credential is user:NAME, org:NAME or named:NAME"
    end

    test "ssh moves the listener", context do
      assert {:ok, [{WardrikDaemon.SSH, ssh}]} =
               read("ssh:\n  port: 2022\n  ip: 0.0.0.0\n", context)

      assert ssh[:port] == 2022
      assert ssh[:ip] == {0, 0, 0, 0}

      assert {:error, port} = read("ssh:\n  port: 70000\n", context)
      assert port =~ "ssh.port is a port number"
      assert {:error, ip} = read("ssh:\n  ip: nowhere\n", context)
      assert ip =~ "ssh.ip is an address"
    end

    test "http moves the API", context do
      assert {:ok, [{WardrikHTTP, http}]} = read("http:\n  port: 8080\n  ip: 0.0.0.0\n", context)
      assert http[:port] == 8080
      assert http[:ip] == {0, 0, 0, 0}

      assert {:error, ip} = read("http:\n  ip: nowhere\n", context)
      assert ip =~ "http.ip is an address"
      assert {:error, key} = read("http:\n  tls: true\n", context)
      assert key =~ "http.tls is not a setting; expected one of port, ip, trusted_workers"
    end

    test "http trusts tool workers' answers only where it says so", context do
      assert {:ok, [{WardrikHTTP, http}]} = read("http:\n  trusted_workers: true\n", context)
      assert http == [trusted_workers: true]

      assert {:error, message} = read("http:\n  trusted_workers: yes please\n", context)
      assert message =~ "http.trusted_workers is true or false"
    end

    test "notify names targets, each Slack or a webhook", context do
      yaml = """
      notify:
        ops:
          slack:
            channel: "#ops"
            token: xoxb-1
            app_token: xapp-1
            approvers: [U1]
        audit:
          webhook:
            url: https://hooks.example.com/wardrik
      """

      assert {:ok, [{WardrikNotify, notify}]} = read(yaml, context)

      assert Enum.sort(notify[:targets]) == [
               audit:
                 {WardrikNotify.Webhook,
                  [url: "https://hooks.example.com/wardrik", orgs: ["default"]]},
               ops:
                 {WardrikNotify.Slack,
                  [
                    app_token: "xapp-1",
                    approvers: ["U1"],
                    channel: "#ops",
                    token: "xoxb-1",
                    orgs: ["default"]
                  ]}
             ]
    end

    test "a notify target that does not read says where", context do
      assert {:error, message} = read("notify:\n  ops:\n    email: {to: a}\n", context)
      assert message =~ "notify.ops is one of slack or webhook"

      assert {:error, message} = read("notify:\n  ops:\n    slack: {channel: x}\n", context)
      assert message =~ "notify.ops.slack.token is required"

      assert {:error, message} =
               read("notify:\n  ops:\n    webhook: {url: x, colour: red}\n", context)

      assert message =~ "notify.ops.webhook.colour is not a setting"
    end

    test "file/1 finds config.yaml or config.yml, and refuses both", %{tmp_dir: dir} do
      assert Config.file(dir) == {:ok, Path.join(dir, "config.yaml")}

      File.write!(Path.join(dir, "config.yml"), "")
      assert Config.file(dir) == {:ok, Path.join(dir, "config.yml")}

      File.write!(Path.join(dir, "config.yaml"), "")
      assert {:error, message} = Config.file(dir)
      assert message =~ "both config.yaml and config.yml"
    end

    test "a provider names how its users authorize", context do
      assert {:ok, [{WardrikOAuth, oauth}]} =
               read(
                 "oauth:\n  providers:\n    github:\n      resource: https://x\n      flow: device\n",
                 context
               )

      assert oauth[:providers][:github][:flow] == :device

      assert {:error, message} =
               read(
                 "oauth:\n  providers:\n    github:\n      resource: https://x\n      flow: phone\n",
                 context
               )

      assert message =~ "oauth.providers.github.flow is auto, browser or device"
    end

    test "a provider's client secret goes only to an issuer it names", context do
      assert {:error, message} =
               read(
                 "oauth:\n  providers:\n    github:\n      resource: https://x\n" <>
                   "      client_id: a\n      client_secret: s\n",
                 context
               )

      assert message =~
               "oauth.providers.github.client_secret is sent only to an issuer the provider names"

      assert {:ok, [{WardrikOAuth, oauth}]} =
               read(
                 "oauth:\n  providers:\n    github:\n      resource: https://x\n" <>
                   "      issuer: https://y\n      client_id: a\n      client_secret: s\n",
                 context
               )

      assert oauth[:providers][:github][:client_secret] == "s"
    end

    test "a cluster of nodes on this machine is found by name, and counted", context do
      assert {:ok, [{WardrikDaemon.Cluster, cluster}]} =
               read("cluster:\n  nodes: [a, b, c]\n", context)

      nodes = [:wardrik_a@localhost, :wardrik_b@localhost, :wardrik_c@localhost]
      assert cluster[:nodes] == nodes
      assert cluster[:size] == 3

      assert [
               %WardrikDaemon.Cluster.Topology{
                 strategy: %WardrikDaemon.Cluster.Epmd{hosts: ^nodes}
               }
             ] =
               cluster[:topologies]
    end

    test "a cluster across machines names each node in full", context do
      assert {:ok, [{WardrikDaemon.Cluster, cluster}]} =
               read("cluster:\n  nodes: [wardrik@box1, wardrik@box2.tail.ts.net]\n", context)

      assert cluster[:nodes] == [:wardrik@box1, :"wardrik@box2.tail.ts.net"]
      assert cluster[:size] == 2
    end

    test "a cluster found by DNS gives its size", context do
      assert {:ok, [{WardrikDaemon.Cluster, cluster}]} =
               read("cluster:\n  dns: wardrik.internal\n  size: 3\n", context)

      assert cluster[:size] == 3
      refute Keyword.has_key?(cluster, :nodes)

      assert [
               %WardrikDaemon.Cluster.Topology{
                 strategy: %WardrikDaemon.Cluster.DNSPoll{query: "wardrik.internal"}
               }
             ] =
               cluster[:topologies]
    end

    test "a cluster that does not read says why", context do
      for {yaml, message} <- [
            {"cluster:\n  dns: wardrik.internal\n", "cluster.size is required with dns"},
            {"cluster:\n  dns: wardrik.internal\n  size: 0\n", "cluster.size is a whole number"},
            {"cluster:\n  nodes: [a, b]\n  size: 3\n", "cluster.size is not a setting"},
            {"cluster:\n  nodes: [a]\n  dns: x\n", "cluster has both nodes and dns"},
            {"cluster:\n  nodes: []\n", "cluster.nodes is a list of node names"},
            {"cluster:\n  nodes: [a, wardrik@box2]\n",
             "cluster.nodes mixes names on this machine"},
            {"cluster:\n  nodes: [a, a]\n", "cluster.nodes names a twice"},
            {"cluster:\n  nodes: [a, b c]\n", ~s(cluster.nodes.1 is "b c")},
            {"cluster: {}\n", "cluster names its nodes, or the dns name"}
          ] do
        assert {:error, error} = read(yaml, context)
        assert error =~ message
      end
    end

    test "storage in Postgres names the database", context do
      assert {:ok, [{Wardrik.Store, store}]} =
               read(
                 "storage:\n  postgres:\n    url: postgres://w:secret@db.internal/w\n",
                 context
               )

      assert store == [adapter: WardrikEcto.Store, url: "postgres://w:secret@db.internal/w"]
    end

    test "storage in S3 names the bucket, and how to reach it", context do
      key = env("key-id")

      assert {:ok, [{Wardrik.Store, store}]} =
               read(
                 """
                 storage:
                   s3:
                     bucket: wardrik
                     endpoint: https://acct.r2.cloudflarestorage.com
                     region: auto
                     prefix: box1
                     access_key_id: ${#{key}}
                     secret_access_key: secret
                 """,
                 context
               )

      assert Enum.sort(store) == [
               access_key_id: "key-id",
               adapter: WardrikS3.Store,
               bucket: "wardrik",
               endpoint: "https://acct.r2.cloudflarestorage.com",
               prefix: "box1",
               region: "auto",
               secret_access_key: "secret"
             ]
    end

    test "empty storage leaves the store as it is", context do
      assert {:ok, [{Wardrik.Store, []}]} = read("storage: {}\n", context)
    end

    test "storage that does not read says why", context do
      s3 = "storage:\n  s3:\n    bucket: b\n    access_key_id: a\n    secret_access_key: s\n"

      for {yaml, message} <- [
            {"storage:\n  postgres: {}\n", "storage.postgres.url is required"},
            {"storage:\n  postgres:\n    url: mysql://db/w\n",
             "storage.postgres.url is a postgres:// URL"},
            {"storage:\n  postgres:\n    url: postgres:///w\n",
             "storage.postgres.url is a postgres:// URL"},
            {"storage:\n  postgres:\n    url: 5\n", "storage.postgres.url is text"},
            {"storage:\n  postgres:\n    url: postgres://db/w\n    pool: 3\n",
             "storage.postgres.pool is not a setting"},
            {s3, "storage.s3.endpoint is required"},
            {s3 <> "    endpoint: r2.example\n", "storage.s3.endpoint is an https:// URL"},
            {s3 <> "    endpoint: https://r2.example\n    region: \"\"\n",
             "storage.s3.region is text"},
            {"storage:\n  ekv: {}\n",
             "storage.ekv is not a setting; expected one of postgres, s3"},
            {"storage:\n  postgres:\n    url: postgres://db/w\n  s3:\n    bucket: b\n",
             "storage names one store, postgres or s3"},
            {"storage: [s3]\n", "storage is a set of keys"}
          ] do
        assert {:error, error} = read(yaml, context)
        assert error =~ message
      end
    end

    test "an unknown section is refused", context do
      assert {:error, message} = read("agents:\n  x: 1\n", context)
      assert message =~ "agents is not a section"
    end

    test "a file that is not a set of sections says so", context do
      assert {:error, message} = read("- a\n- b\n", context)
      assert message =~ "the file is a set of sections"
    end

    test "a file that is not YAML says so", context do
      assert {:error, message} = read("mcp: [a\n", context)
      assert message =~ "config.yaml: is not YAML"
    end
  end

  describe "the directories" do
    @describetag tmp_dir: false

    setup do
      saved =
        Map.new(
          ~w(WARDRIK_CONFIG_DIR WARDRIK_STATE_DIR XDG_CONFIG_HOME XDG_STATE_HOME),
          &{&1, System.get_env(&1)}
        )

      Enum.each(saved, fn {name, _value} -> System.delete_env(name) end)

      on_exit(fn ->
        Enum.each(saved, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)
    end

    test "follow the XDG base directories" do
      assert Config.config_dir() == Path.expand("~/.config/wardrik")
      assert Config.state_dir() == Path.expand("~/.local/state/wardrik")

      System.put_env("XDG_CONFIG_HOME", "/xdg/config")
      System.put_env("XDG_STATE_HOME", "/xdg/state")

      assert Config.config_dir() == "/xdg/config/wardrik"
      assert Config.state_dir() == "/xdg/state/wardrik"
    end

    test "are each overridden by their own variable" do
      System.put_env("XDG_CONFIG_HOME", "/xdg/config")
      System.put_env("WARDRIK_CONFIG_DIR", "/etc/wardrik")
      System.put_env("WARDRIK_STATE_DIR", "/var/lib/wardrik")

      assert Config.config_dir() == "/etc/wardrik"
      assert Config.state_dir() == "/var/lib/wardrik"
    end
  end

  describe "boot/1" do
    @describetag tmp_dir: false

    test "counts the store's quorum over the cluster, where the store is on the nodes" do
      cluster = [nodes: [:a@box, :b@box, :c@box], size: 3]

      assert Config.boot([{WardrikMCP, servers: []}, {WardrikDaemon.Cluster, cluster}]) == [
               {WardrikDaemon.Cluster, cluster},
               {Wardrik.Store, cluster_size: 3}
             ]
    end

    test "leaves a store kept elsewhere as storage names it" do
      store = [adapter: WardrikS3.Store, bucket: "b"]

      assert Config.boot([{WardrikDaemon.Cluster, size: 3}, {Wardrik.Store, store}]) == [
               {WardrikDaemon.Cluster, size: 3},
               {Wardrik.Store, store}
             ]

      assert Config.boot([{Wardrik.Store, store}]) == [{Wardrik.Store, store}]
    end

    test "is nothing where the file names neither" do
      assert Config.boot([{WardrikMCP, servers: []}]) == []
    end
  end

  describe "apply/1" do
    @describetag tmp_dir: false

    test "leaves the store's settings, which a release took as it booted" do
      before = Application.get_env(:wardrik, Wardrik.Store)
      :ok = Config.apply([{Wardrik.Store, adapter: Wardrik.Store.Memory}])
      assert Application.get_env(:wardrik, Wardrik.Store) == before
    end

    test "merges over what the package already holds" do
      package = :"Elixir.WardrikDaemon.ConfigTest.Package#{System.unique_integer([:positive])}"
      Application.put_env(:wardrik, package, kept: 1, replaced: 1)
      on_exit(fn -> Application.delete_env(:wardrik, package) end)

      :ok = Config.apply([{package, replaced: 2}])

      assert Application.get_env(:wardrik, package) == [kept: 1, replaced: 2]
    end
  end
end
