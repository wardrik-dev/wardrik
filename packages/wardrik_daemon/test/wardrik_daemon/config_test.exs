defmodule WardrikDaemon.ConfigTest do
  use ExUnit.Case, async: false

  alias WardrikDaemon.Config

  @moduletag :tmp_dir

  # Every file names the deployment's org first; what each other test reads
  # is the rest.
  defp read(yaml, context, opts \\ []) do
    with {:ok, [{WardrikDaemon, _org} | settings]} <- read_all(yaml, context, opts),
         do: {:ok, settings}
  end

  defp read_all(yaml, %{tmp_dir: dir}, opts \\ []) do
    file = Path.join(dir, "config.yaml")
    File.write!(file, yaml)
    Config.read(file, opts)
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
      assert {:ok, [{WardrikDaemon, [org: "default"]}, {WardrikDaemon.SSH, _ssh}]} =
               read_all("ssh: {port: 2223}\n", context)

      assert {:ok, [{WardrikDaemon, [org: "acme"]}]} = read_all("org: acme\n", context)

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

    test "a server with a url is reached over HTTP, with the credential it names", context do
      assert {:ok, [{WardrikMCP, servers: [github: server]}]} =
               read(
                 """
                 mcp:
                   github:
                     url: https://api.githubcopilot.com/mcp/
                     headers:
                       x-team: core
                     credential: github
                 """,
                 context
               )

      assert server[:transport] ==
               {:streamable_http,
                base_url: "https://api.githubcopilot.com/mcp/", headers: %{"x-team" => "core"}}

      assert server[:credential] == "github"
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

    test "a variable that is not set says to set it in the env file", %{tmp_dir: dir} = context do
      yaml = ~s(mcp:\n  a: {command: "${WARDRIK_CONFIG_TEST_UNSET}"}\n)
      env = Path.join(dir, "env")

      assert {:error, message} = read(yaml, context)

      assert message =~
               "set it in the environment wardrik runs in, or create #{env} with a line " <>
                 "WARDRIK_CONFIG_TEST_UNSET=..."

      File.write!(env, "OTHER=1\n")

      assert {:error, message} = read(yaml, context, vault: fn _name -> nil end)

      assert message =~
               "wardrik vault put WARDRIK_CONFIG_TEST_UNSET seals it, or add " <>
                 "WARDRIK_CONFIG_TEST_UNSET=... to #{env}, or set it in the environment"

      assert {:error, message} =
               read(~s(vault:\n  keys: ["${WARDRIK_CONFIG_TEST_UNSET}"]\n), context,
                 vault: fn _name -> "from-vault" end
               )

      assert message =~
               "since the vault cannot unlock itself, so add WARDRIK_CONFIG_TEST_UNSET=... to #{env}"
    end

    test "the env file is WARDRIK_ENV_FILE where that is set", %{tmp_dir: dir} do
      System.put_env("WARDRIK_ENV_FILE", "/elsewhere/env")
      on_exit(fn -> System.delete_env("WARDRIK_ENV_FILE") end)

      assert Config.env_file(dir) == "/elsewhere/env"
      System.delete_env("WARDRIK_ENV_FILE")
      assert Config.env_file(dir) == Path.join(dir, "env")
    end

    test "${NAME} the environment does not set is read from the vault, if it is given one",
         context do
      yaml =
        "mcp:\n  linear:\n    url: https://mcp.linear.app/mcp\n    headers: {authorization: \"Bearer ${LIN_TOKEN}\"}\n"

      vault = fn "LIN_TOKEN" -> "from-vault" end

      assert {:ok, [{WardrikMCP, servers: [linear: server]}]} = read(yaml, context, vault: vault)
      assert {:streamable_http, opts} = server[:transport]
      assert opts[:headers] == %{"authorization" => "Bearer from-vault"}

      assert {:error, message} = read(yaml, context)
      assert message =~ "mcp.linear.headers.authorization names ${LIN_TOKEN}, which is not set"

      assert {:error, message} = read(yaml, context, vault: fn _name -> nil end)

      assert message =~
               "names ${LIN_TOKEN}, which neither the environment nor the vault sets; " <>
                 "wardrik vault put LIN_TOKEN seals it"
    end

    test "the environment comes before the vault", context do
      name = env("from-environment")

      assert {:ok, [{WardrikVault, keys: ["from-environment"]}]} =
               read(~s(vault:\n  keys: ["${#{name}}"]\n), context, vault: fn _ -> "vault" end)

      assert {:ok, [{WardrikMCP, servers: [a: server]}]} =
               read("mcp:\n  a: {command: \"${#{name}}\"}\n", context, vault: fn _ -> "vault" end)

      assert {:stdio, opts} = server[:transport]
      assert opts[:command] == "from-environment"
    end

    test "storage, cluster, http and vault never read the vault, and say why", context do
      vault = fn _name -> "from-vault" end

      for {yaml, why} <- [
            {"storage:\n  postgres: {url: \"${DB_URL}\"}\n",
             "since the vault is kept in the store"},
            {"cluster:\n  dns: \"${CLUSTER_DNS}\"\n",
             "as the node boots, before the vault can be"},
            {"http:\n  ip: \"${HTTP_IP}\"\n",
             "http reads the environment alone, as the node boots"},
            {~s(vault:\n  keys: ["${KEY}"]\n), "since the vault cannot unlock itself"}
          ] do
        assert {:error, message} = read(yaml, context, vault: vault)
        assert message =~ "which is not set; "
        assert message =~ why
      end
    end

    test "only reads the sections it names", context do
      yaml = """
      mcp:
        linear: {url: "https://mcp.linear.app/mcp", headers: {authorization: "${UNSET_ANYWHERE}"}}
      cluster:
        nodes: [a, b]
      """

      assert {:error, _unset} = read(yaml, context)

      assert {:ok, [{WardrikDaemon.Cluster, cluster}]} =
               read(yaml, context, only: ~w(storage cluster))

      assert cluster[:size] == 2
    end

    test "defaults keep what an agent file takes, and refuse what it does not", context do
      yaml = "defaults:\n  model: anthropic:claude-sonnet-5\n  tools: [web_search]\n"

      assert {:ok, [{WardrikDaemon.Agents, defaults: defaults}]} = read(yaml, context)
      assert defaults == %{"model" => "anthropic:claude-sonnet-5", "tools" => ["web_search"]}

      assert {:error, message} = read("defaults:\n  name: helper\n", context)
      assert message =~ "defaults.name is not a setting; expected one of model, tools, policy"
    end

    test "defaults' idle_timeout is seconds, or infinity", context do
      assert {:ok, [{WardrikDaemon.Agents, defaults: %{"idle_timeout" => 600}}]} =
               read("defaults:\n  idle_timeout: 600\n", context)

      assert {:ok, [{WardrikDaemon.Agents, defaults: %{"idle_timeout" => "infinity"}}]} =
               read("defaults:\n  idle_timeout: infinity\n", context)

      assert {:error, message} = read("defaults:\n  idle_timeout: 0\n", context)
      assert message =~ "defaults.idle_timeout is a whole number of seconds, or infinity"
    end

    test "tools lists what one call to a tool costs, by name or pattern", context do
      yaml = "tools:\n  web_search:\n    price: 0.005\n  github/*:\n    price: 0\n"

      assert {:ok, [{WardrikDaemon.AgentFile, tool_prices: prices}]} = read(yaml, context)
      assert prices == %{"web_search" => 0.005, "github/*" => 0}

      assert {:error, message} = read("tools:\n  web_search:\n    price: cheap\n", context)
      assert message =~ "tools.web_search.price is a price in US dollars"

      assert {:error, message} = read("tools:\n  web_search:\n    cost: 1\n", context)
      assert message =~ "tools.web_search.cost is not a setting; expected one of price"

      assert {:error, message} = read("tools:\n  write_file(notes/*):\n    price: 1\n", context)
      assert message =~ "names the tool alone"
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
      assert {:ok, [{WardrikMCP, servers: [docs: docs, github: github, notes: notes]}]} =
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
                   docs:
                     command: npx
                     gated: false
                 """,
                 context
               )

      assert github[:gated] == ["create_*", "issue_write"]
      refute Keyword.has_key?(github, :trusted)
      assert notes[:gated] == true
      assert notes[:trusted] == true
      assert docs[:gated] == false

      assert {:error, gated} = read("mcp:\n  a:\n    command: x\n    gated: [1]\n", context)
      assert gated =~ "mcp.a.gated is true, false, or a list of the server's tool names"
      assert {:error, trusted} = read("mcp:\n  a:\n    command: x\n    trusted: 1\n", context)
      assert trusted =~ "mcp.a.trusted is true or false"
    end

    test "a credential is a name", context do
      for credential <- ["user:github", "a/b", "_x", "\"\""] do
        assert {:error, message} =
                 read("mcp:\n  a:\n    url: https://x\n    credential: #{credential}\n", context)

        assert message =~ "mcp.a.credential is"
        assert message =~ "the name of a credential"
      end
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

    test "channels names chat media, each of a type its adapter reads", context do
      yaml = """
      channels:
        chat:
          type: test
          room_prefix: wardrik-
        other:
          type: test
      """

      assert {:ok,
              [
                {WardrikChannel,
                 [
                   channels: channels,
                   orgs: orgs,
                   creates: _creates,
                   approvers: approvers,
                   admins: admins
                 ]}
              ]} = read(yaml, context)

      assert Enum.sort(channels) == [
               chat: {WardrikDaemon.Test.Channel, [room_prefix: "wardrik-"]},
               other: {WardrikDaemon.Test.Channel, []}
             ]

      assert Enum.sort(orgs) == [chat: ["default"], other: ["default"]]
      assert Enum.sort(approvers) == [chat: [], other: []]
      assert Enum.sort(admins) == [chat: [], other: []]

      assert {:ok, [{WardrikChannel, settings}]} =
               read("channels:\n  chat: {type: test, approvers: [\"@maria\"]}\n", context)

      assert settings[:approvers] == [chat: ["@maria"]]

      assert {:error, message} =
               read("channels:\n  chat: {type: test, approvers: maria}\n", context)

      assert message =~ "channels.chat.approvers is a list of who may answer"

      assert {:ok, [{WardrikChannel, settings}]} =
               read("channels:\n  chat: {type: test, admins: [\"@jon\"]}\n", context)

      assert settings[:admins] == [chat: ["@jon"]]
      assert {:error, message} = read("channels:\n  chat: {type: test, admins: jon}\n", context)
      assert message =~ "channels.chat.admins is a list"

      yaml = "channels:\n  chat: {type: test, org: \"*\"}\n  acme: {type: test, org: [acme]}\n"
      assert {:ok, [{WardrikChannel, settings}]} = read(yaml, context)
      assert Enum.sort(settings[:orgs]) == [acme: ["acme"], chat: :all]
      assert Enum.sort(settings[:creates]) == [acme: true, chat: true]

      assert {:ok, [{WardrikChannel, settings}]} =
               read("channels:\n  chat: {type: test, create: false}\n", context)

      assert settings[:creates] == [chat: false]

      assert {:error, message} = read("channels:\n  chat: {type: test, create: maybe}\n", context)
      assert message =~ "channels.chat.create is true or false"

      assert {:error, message} = read("channels:\n  chat: {type: pigeon}\n", context)
      assert message =~ "channels.chat.type is the kind of channel: test"

      assert {:error, message} = read("channels:\n  chat: {type: test, colour: red}\n", context)
      assert message =~ "channels.chat.room_prefix is the only setting"
    end

    test "notify names targets, each a room in a channel or a webhook", context do
      yaml = """
      channels:
        chat: {type: test}
      notify:
        ops:
          channel: chat
          room: "#ops"
          approvers: ["@maria"]
        audit:
          webhook:
            url: https://hooks.example.com/wardrik
      """

      assert {:ok, sections} = read(yaml, context)
      notify = sections[WardrikNotify]

      assert Enum.sort(notify[:targets]) == [
               audit:
                 {WardrikNotify.Webhook,
                  [url: "https://hooks.example.com/wardrik", orgs: ["default"]]},
               ops:
                 {WardrikChannel.Notices,
                  [
                    channel: {WardrikDaemon.Test.Channel, []},
                    room: "#ops",
                    approvers: ["@maria"],
                    orgs: ["default"]
                  ]}
             ]
    end

    test "a notify target that does not read says where", context do
      assert {:error, message} = read("notify:\n  ops:\n    email: {to: a}\n", context)
      assert message =~ "notify.ops is a webhook, or a channel and a room in it"

      assert {:error, message} = read("notify:\n  ops: {channel: chat, room: x}\n", context)
      assert message =~ "notify.ops.channel is chat, which config.yaml's channels does not name"

      assert {:error, message} = read("notify:\n  ops: {channel: chat}\n", context)
      assert message =~ "notify.ops.room is required"

      assert {:error, message} =
               read("notify:\n  ops: {channel: chat, room: x, approvers: maria}\n", context)

      assert message =~ "notify.ops.approvers is a list"

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

    test "base_url is the deployment's address, which oauth's redirect is under unless it says",
         context do
      assert {:ok,
              [
                {WardrikDaemon, [org: "default", base_url: "https://agents.example.com"]},
                {WardrikOAuth, [redirect: redirect]}
              ]} =
               read_all(
                 "base_url: https://agents.example.com/\noauth:\n  redirect:\n    port: 4600\n",
                 context
               )

      assert Enum.sort(redirect) == [port: 4600, url: "https://agents.example.com/oauth"]

      assert {:ok, [{WardrikOAuth, [redirect: [url: "https://elsewhere.example.com/cb"]]}]} =
               read(
                 "base_url: https://agents.example.com\n" <>
                   "oauth:\n  redirect:\n    url: https://elsewhere.example.com/cb\n",
                 context
               )

      assert {:error, message} = read("base_url: http://agents.example.com\n", context)
      assert message =~ "base_url is an https:// URL, or http:// on loopback"
    end

    test "base_url/1 is this machine's loopback where the file names none" do
      config = Config.new(sections: [{WardrikDaemon, org: "default"}, {WardrikHTTP, port: 4800}])
      assert Config.base_url(config) == "http://127.0.0.1:4800"

      config = Config.new(sections: [{WardrikDaemon, base_url: "https://agents.example.com"}])
      assert Config.base_url(config) == "https://agents.example.com"
    end

    test "oauth.redirect names where a browser comes back to, and where the daemon listens",
         context do
      assert {:ok, [{WardrikOAuth, oauth}]} =
               read(
                 "oauth:\n  redirect:\n    url: https://agents.example.com/oauth/\n" <>
                   "    ip: 0.0.0.0\n    port: 4600\n    open: false\n",
                 context
               )

      assert Enum.sort(oauth[:redirect]) ==
               [
                 ip: {0, 0, 0, 0},
                 open: false,
                 port: 4600,
                 url: "https://agents.example.com/oauth"
               ]

      assert {:ok, [{WardrikOAuth, [redirect: [url: "http://localhost:4599"]]}]} =
               read("oauth:\n  redirect:\n    url: http://localhost:4599\n", context)

      for {yaml, said} <- [
            {"url: http://agents.example.com", "url is an https:// URL, or http:// on loopback"},
            {"url: https://agents.example.com/?a=1", "url is an https:// URL"},
            {"url: https://agents.example.com/#top", "url is an https:// URL"},
            {"url: 4599", "url is an https:// URL"},
            {"ip: everywhere", "ip is an address"},
            {"port: 70000", "port is a port number"},
            {"open: sometimes", "open is true or false"},
            {"uri: https://agents.example.com", "uri is not"}
          ] do
        assert {:error, message} = read("oauth:\n  redirect:\n    #{yaml}\n", context)
        assert message =~ "oauth.redirect." <> said
      end

      assert {:error, message} =
               read(
                 "oauth:\n  providers:\n    github:\n      resource: https://x\n" <>
                   "      redirect_uri: https://y\n",
                 context
               )

      assert message =~ "oauth.providers.github.redirect_uri"
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

    test "a provider sends more with the authorization request, but not what Wardrik sets",
         context do
      assert {:ok, [{WardrikOAuth, oauth}]} =
               read(
                 "oauth:\n  providers:\n    google:\n      resource: https://x\n" <>
                   "      authorization_params:\n        access_type: offline\n" <>
                   "        prompt: consent\n        max_age: 0\n",
                 context
               )

      assert oauth[:providers][:google][:authorization_params] ==
               %{"access_type" => "offline", "prompt" => "consent", "max_age" => "0"}

      assert {:error, message} =
               read(
                 "oauth:\n  providers:\n    google:\n      resource: https://x\n" <>
                   "      authorization_params:\n        redirect_uri: https://y\n",
                 context
               )

      assert message =~
               "oauth.providers.google.authorization_params.redirect_uri is one Wardrik sets itself"

      assert {:error, message} =
               read(
                 "oauth:\n  providers:\n    google:\n      resource: https://x\n" <>
                   "      authorization_params: offline\n",
                 context
               )

      assert message =~ "oauth.providers.google.authorization_params is a table"
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
      assert {:ok, [{WardrikStore, store}]} =
               read(
                 "storage:\n  postgres:\n    url: postgres://w:secret@db.internal/w\n",
                 context
               )

      assert store == [adapter: WardrikEcto.Store, url: "postgres://w:secret@db.internal/w"]
    end

    test "storage in S3 names the bucket, and how to reach it", context do
      key = env("key-id")

      assert {:ok, [{WardrikStore, store}]} =
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
      assert {:ok, [{WardrikStore, []}]} = read("storage: {}\n", context)
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
               {WardrikStore, cluster_size: 3}
             ]
    end

    test "leaves a store kept elsewhere as storage names it" do
      store = [adapter: WardrikS3.Store, bucket: "b"]

      assert Config.boot([{WardrikDaemon.Cluster, size: 3}, {WardrikStore, store}]) == [
               {WardrikDaemon.Cluster, size: 3},
               {WardrikStore, store}
             ]

      assert Config.boot([{WardrikStore, store}]) == [{WardrikStore, store}]
    end

    test "keeps the HTTP API's settings, for what starts before the daemon" do
      http = [trusted_workers: true, port: 8080]

      assert Config.boot([{WardrikMCP, servers: []}, {WardrikHTTP, http}]) == [
               {WardrikHTTP, http}
             ]
    end

    test "is nothing where the file names none of them" do
      assert Config.boot([{WardrikMCP, servers: []}]) == []
    end
  end

  describe "load/1" do
    test "reads the file over the release's settings, and keeps the vault's keys", %{
      tmp_dir: dir
    } do
      File.write!(Path.join(dir, "config.yaml"), "org: acme\nvault:\n  keys: [\"${KEYED}\"]\n")
      key = WardrikVault.generate_key()
      System.put_env("KEYED", key)
      on_exit(fn -> System.delete_env("KEYED") end)

      base = [{WardrikVault, environment: ["SEARCH_API_KEY"]}, {WardrikMCP, servers: []}]

      assert {:ok, %Config{} = config} =
               Config.load(
                 store: Wardrik.Test.store(),
                 base: base,
                 config_dir: dir,
                 data_dir: dir
               )

      assert Config.org(config) == "acme"
      assert Config.section(config, WardrikVault)[:environment] == ["SEARCH_API_KEY"]
      assert Config.section(config, WardrikVault)[:keys] == [key]
      assert Config.section(config, WardrikMCP) == [servers: []]
      assert config.config_dir == dir
    end

    test "gives the vault the data home's key file where nothing else names one", %{tmp_dir: dir} do
      {:ok, file} = WardrikDaemon.VaultKey.make(dir)
      {:ok, key} = WardrikDaemon.VaultKey.read(file)

      assert {:ok, config} =
               Config.load(store: Wardrik.Test.store(), config_dir: dir, data_dir: dir)

      assert Config.section(config, WardrikVault)[:keys] == [key]
    end

    test "merges each module's settings over the release's", %{tmp_dir: _dir} do
      assert Config.merge([{WardrikMCP, kept: 1, replaced: 1}], [{WardrikMCP, replaced: 2}]) ==
               [{WardrikMCP, kept: 1, replaced: 2}]
    end
  end
end
