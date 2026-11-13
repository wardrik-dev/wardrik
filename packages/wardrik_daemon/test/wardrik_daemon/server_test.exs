defmodule WardrikDaemon.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog, only: [capture_log: 1]
  import WardrikDaemon.Test

  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLIToken
  alias WardrikDaemon.Tokens
  alias WardrikDaemon.Tokens.Token

  setup context do
    context = dirs(context)

    write(context, "config.yaml", """
    org: acme
    http: {port: #{free_port()}}
    defaults: {model: #{model()}}
    ssh: {}
    """)

    write(context, "policies/careful.yaml", "ask: [echo]\n")

    write(context, "agents/triage.md", """
    ---
    description: Triages.
    policy: careful
    ---
    You watch the queue.
    """)

    write(context, "agents/broken.md", "---\ntools: [nope]\n---\n")
    context
  end

  test "defines the agents its files declare, and keeps them from the API", context do
    context = start_daemon(context)
    log = context.log

    assert log =~ "Wardrik didn't define broken"
    assert log =~ "ssh isn't supported here yet"

    assert {:ok, %Wardrik.Definition{instructions: "You watch the queue.", policy: "careful"}, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "triage"))

    assert {:error, %Wardrik.Error{type: :conflict}} =
             Wardrik.Agent.forget(context.admin, id(context, "acme", "triage"))
  end

  test "routes an agent file's notices", context do
    write(
      context,
      "agents/digest.md",
      "---\nnotify: {to: [audit], on: [finished]}\n---\nDigest.\n"
    )

    write(context, "config.yaml", """
    org: acme
    http: {port: #{free_port()}}
    defaults: {model: #{model()}}
    notify:
      targets:
        audit: {webhook: {url: "http://127.0.0.1:1/hook"}}
    """)

    context = start_daemon(context)

    assert {:ok, %Wardrik.Definition{notify: %{"to" => ["audit"], "on" => ["finished"]}}, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "digest"))
  end

  test "offers the tools it ships", context do
    write(context, "agents/clock.md", "---\ntools: [run_lua]\n---\nTell the time.\n")
    context = start_daemon(context)

    assert {:ok, %Wardrik.Definition{tools: ["run_lua"]}, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "clock"))

    daemon = %{wardrik: :w, store: :store}

    assert [
             run_lua: WardrikLua,
             web_search: {WardrikBrave, brave: _name},
             deep_research: WardrikResearch,
             agent_create: {WardrikDaemon.CreateAgent, wardrik: :w, store: :store},
             settings: {WardrikDaemon.SettingsTools, daemon: ^daemon},
             help: {WardrikDaemon.HelpTools, daemon: ^daemon}
           ] = WardrikDaemon.Capabilities.all(daemon)
  end

  test "sends every model call through its gateway", context do
    context = start_daemon(context)
    gateway = Module.concat(context.wardrik, Gateway)
    assert is_pid(Process.whereis(gateway))

    wardrik = Wardrik.Instance.fetch!(context.wardrik)
    assert {WardrikGateway, gateway} in wardrik.middleware
  end

  test "gives an agent its files, and context read into every turn", context do
    path = Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")
    config = File.read!(path)

    write(
      context,
      "config.yaml",
      config <> "workspace: {shared: {\"agent:triage\": {read: [\"agent:notes\"]}}}\n"
    )

    write(
      context,
      "agents/notes.md",
      "---\ntools: [files]\ncontext: [MEMORY.md]\nworkspace: {shared: {team: \"agent:triage\"}}\n---\nKeep notes.\n"
    )

    context = start_daemon(context)

    assert {:ok, %Wardrik.Definition{tools: ["files"], context: ["MEMORY.md"]} = notes, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "notes"))

    assert notes.workspace == %{"shared" => %{"team" => id(context, "acme", "triage")}}
  end

  test "reads its files again, and forgets an agent whose file is gone", context do
    context = start_daemon(context)
    triage = id(context, "acme", "triage")
    file = Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents/triage.md")
    File.rm!(file)
    write(context, "agents/notes.md", "Keep notes.")

    capture_log(fn -> assert {:ok, _nodes} = Wardrik.Deployment.reload(context.admin) end)

    assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Agent.read(context.admin, triage)
    assert WardrikDaemon.AgentRecords.named(context.daemon_store, "acme", "triage") == :error

    assert {:ok, _definition, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "notes"))
  end

  test "gives a new file one agent when reloads run at once, as on several nodes", context do
    context = start_daemon(context)
    for n <- 1..5, do: write(context, "agents/new#{n}.md", "Agent #{n}.")

    capture_log(fn ->
      1..3
      |> Enum.map(fn _n -> Task.async(fn -> Wardrik.Deployment.reload(context.admin) end) end)
      |> Task.await_many()
    end)

    assert {:ok, %{"agents" => [_, _, _, _, _, _]}} =
             Wardrik.run(context.admin, "agents.list", %{})
  end

  test "an agent file keeps its ID across reloads, and a rename takes no other agent's",
       context do
    context = start_daemon(context)
    triage = id(context, "acme", "triage")
    helper = agent(context, "acme/@ana", "helper", model: model(), instructions: "Help Ana.")
    dir = Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents")

    capture_log(fn -> assert {:ok, _nodes} = Wardrik.Deployment.reload(context.admin) end)
    assert id(context, "acme", "triage") == triage

    triage_file = Path.join(dir, "triage.md")
    helper_file = Path.join(dir, "helper.md")
    File.rename!(triage_file, helper_file)
    log = capture_log(fn -> assert {:ok, _nodes} = Wardrik.Deployment.reload(context.admin) end)

    assert log =~ "helper is the name of another agent in acme"
    assert id(context, "acme", "helper") == helper

    assert {:ok, %Wardrik.Definition{instructions: "Help Ana."}, []} =
             Wardrik.Agent.definition(context.admin, helper)

    assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Agent.read(context.admin, triage)

    File.rename!(helper_file, triage_file)
    capture_log(fn -> assert {:ok, _nodes} = Wardrik.Deployment.reload(context.admin) end)
    assert id(context, "acme", "triage") not in [triage, helper]
  end

  test "an agent file can't hand its agent to another owner", context do
    context = start_daemon(context)
    triage = id(context, "acme", "triage")
    write(context, "agents/triage.md", "---\nowner: \"@jon\"\n---\nYou watch Jon's queue.\n")

    log = capture_log(fn -> assert {:ok, _nodes} = Wardrik.Deployment.reload(context.admin) end)

    assert log =~ "triage is acme's agent"
    assert WardrikDaemon.Owners.owner(context.daemon_store, triage) == {:ok, "acme"}

    assert {:ok, %Wardrik.Definition{instructions: "You watch the queue."}, []} =
             Wardrik.Agent.definition(context.admin, triage)
  end

  test "keeps an agent whose file no longer reads at its last definition", context do
    context = start_daemon(context)
    write(context, "agents/triage.md", "---\ndescription: [\n---\n")

    log =
      capture_log(fn -> assert {:ok, _nodes} = Wardrik.Deployment.reload(context.admin) end)

    assert log =~ "triage.md: has frontmatter that isn't YAML"

    assert {:ok, %Wardrik.Definition{instructions: "You watch the queue."}, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "triage"))

    assert {:error, %Wardrik.Error{type: :conflict}} =
             Wardrik.Agent.forget(context.admin, id(context, "acme", "triage"))
  end

  test "restarts to read config.yaml as it is when a reload finds it changed", context do
    context = start_daemon(context)
    path = Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")
    started = File.read!(path)
    ref = :telemetry_test.attach_event_handlers(self(), [[:wardrik_daemon, :started]])
    cx = Context.new(context.env)

    write(context, "config.yaml", "defaults: [\n")

    log =
      capture_log(fn ->
        assert {:ok, %{"problems" => [_broken]}} = Context.call(cx, "deployment.reload", %{})
      end)

    assert log =~ "kept config.yaml and policies/ as they read at start"
    refute_received {[:wardrik_daemon, :started], ^ref, _measurements, _meta}

    write(
      context,
      "config.yaml",
      String.replace(started, "{model: #{model()}}", "{model: anthropic:claude-sonnet-4-5}")
    )

    capture_log(fn ->
      assert {:ok, %{"problems" => []}} = Context.call(cx, "deployment.reload", %{})
      assert_receive {[:wardrik_daemon, :started], ^ref, _measurements, _meta}, 20_000
    end)

    assert {:ok, %Wardrik.Definition{model: "anthropic:claude-sonnet-4-5"}, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "triage"))
  end

  test "makes the token the wardrik command acts with, in place of the last", context do
    context = start_daemon(context)
    path = Path.join(context.env["WARDRIK_DATA_HOME"], "cli_token")

    assert {:ok, %{url: "http://127.0.0.1:" <> _port, secret: secret}} = CLIToken.read(path)
    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o077) == 0
    assert {:ok, %Token{subject: "user:admin"}} = Tokens.verify(context.daemon_store, secret)

    CLIToken.issue(context.daemon_store, path, "http://127.0.0.1:1")
    assert Tokens.verify(context.daemon_store, secret) == :error
    assert [%Token{name: "wardrik command"}] = Tokens.list(context.daemon_store)
    none = Path.join(context.root, "none")
    assert CLIToken.read(none) == :error
  end

  test "finds the deployment's secrets in the vault before it opens", context do
    store = Wardrik.Store.ETS.new(name: :"sealed #{context.test}")
    start_supervised!({Wardrik.Store, store})
    key = Wardrik.Vault.generate_key()
    vault = :"vault #{context.test}"
    start_supervised!({Wardrik.Vault, name: vault, store: store, keys: [key]})

    {:ok, _vsn} =
      Wardrik.Vault.put(vault, %Wardrik.Vault.Secret{
        principal: %WardrikCore.Principal{id: "deployment"},
        name: "MODEL",
        value: "m"
      })

    sealed = WardrikDaemon.Running.sealed(store, [key])
    assert sealed.("MODEL") == {:ok, "m"}
    assert sealed.("NOPE") == :error
  end

  test "refuses to start where its config doesn't read", context do
    write(context, "config.yaml", "nope: 1\n")

    assert_raise ArgumentError, ~r/unknown options \[:nope\]/, fn ->
      WardrikDaemon.Server.init(env: context.env, name: :never)
    end
  end

  test "refuses to start as a node its cluster doesn't name", context do
    write(context, "config.yaml", "cluster: {nodes: [a, b]}\n")

    assert_raise ArgumentError, ~r/isn't one of cluster.nodes: wardrik_a@localhost/, fn ->
      WardrikDaemon.Server.init(env: context.env, name: :never)
    end
  end

  test "shares its HTTP API's port with the cluster's other nodes on this machine", context do
    port = free_port()
    {:ok, held} = :gen_tcp.listen(port, ip: {127, 0, 0, 1}, reuseaddr: true)

    write(context, "config.yaml", """
    org: acme
    http: {port: #{port}}
    defaults: {model: #{model()}}
    cluster: {dns: localhost, size: 1}
    """)

    context = start_daemon(context)
    assert context.log =~ "Another node holds port #{port}"
    :ok = :gen_tcp.close(held)
  end
end
