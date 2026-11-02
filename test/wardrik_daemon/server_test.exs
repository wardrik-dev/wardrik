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
    cluster: {}
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
    assert log =~ "cluster isn't supported here yet"

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

    assert [
             run_lua: WardrikLua,
             web_search: {WardrikBrave, brave: _name},
             deep_research: WardrikResearch
           ] =
             WardrikDaemon.Capabilities.all(:w)
  end

  test "gives an agent its files, and context read into every turn", context do
    config = File.read!(Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml"))

    write(
      context,
      "config.yaml",
      config <> "workspace: {shared: {triage: {read: [notes]}}}\n"
    )

    write(
      context,
      "agents/notes.md",
      "---\ntools: [files]\ncontext: [MEMORY.md]\nworkspace: {shared: {team: triage}}\n---\nKeep notes.\n"
    )

    context = start_daemon(context)

    assert {:ok, %Wardrik.Definition{tools: ["files"], context: ["MEMORY.md"]} = notes, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "notes"))

    assert notes.workspace == %{"shared" => %{"team" => id(context, "acme", "triage")}}
  end

  test "reads its files again, and forgets an agent whose file is gone", context do
    context = start_daemon(context)
    triage = id(context, "acme", "triage")
    File.rm!(Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents/triage.md"))
    write(context, "agents/notes.md", "Keep notes.")

    capture_log(fn -> assert {:ok, _nodes} = Wardrik.Deployment.reload(context.admin) end)

    assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Agent.read(context.admin, triage)
    assert WardrikDaemon.AgentRecords.named(context.daemon_store, "acme", "triage") == :error

    assert {:ok, _definition, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "notes"))
  end

  test "an agent file keeps its ID across reloads, and a rename takes no other agent's",
       context do
    context = start_daemon(context)
    triage = id(context, "acme", "triage")
    helper = agent(context, "acme/@ana", "helper", model: model(), instructions: "Help Ana.")
    dir = Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents")

    capture_log(fn -> assert {:ok, _nodes} = Wardrik.Deployment.reload(context.admin) end)
    assert id(context, "acme", "triage") == triage

    File.rename!(Path.join(dir, "triage.md"), Path.join(dir, "helper.md"))
    log = capture_log(fn -> assert {:ok, _nodes} = Wardrik.Deployment.reload(context.admin) end)

    assert log =~ "helper is the name of another agent in acme"
    assert id(context, "acme", "helper") == helper

    assert {:ok, %Wardrik.Definition{instructions: "Help Ana."}, []} =
             Wardrik.Agent.definition(context.admin, helper)

    assert {:error, %Wardrik.Error{type: :not_found}} = Wardrik.Agent.read(context.admin, triage)

    File.rename!(Path.join(dir, "helper.md"), Path.join(dir, "triage.md"))
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
    assert CLIToken.read(Path.join(context.root, "none")) == :error
  end

  test "finds the deployment's secrets in the vault before it opens", context do
    store = WardrikStore.ETS.new(name: :"sealed #{context.test}")
    start_supervised!({WardrikStore, store})
    key = WardrikVault.generate_key()
    vault = :"vault #{context.test}"
    start_supervised!({WardrikVault, name: vault, store: store, keys: [key]})

    {:ok, _vsn} =
      WardrikVault.put(vault, %WardrikVault.Secret{
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
end
