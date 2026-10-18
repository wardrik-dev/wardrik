defmodule WardrikDaemon.AgentsTest do
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]
  use Mimic

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias WardrikDaemon.Agents
  alias WardrikDaemon.Test.Host

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup %{tmp_dir: dir} do
    org = "agents-#{System.unique_integer([:positive])}"
    Host.declare([org, "acme"])

    on_exit(fn ->
      prefix = Prefix.parse!(org <> "/")

      for trigger <- WardrikTrigger.list(prefix),
          do: WardrikTrigger.delete(trigger.agent, trigger.name)

      Fleet.forget_under(prefix)
    end)

    %{dir: dir, org: org}
  end

  defp write(%{dir: dir, org: org}, name, front) do
    File.mkdir_p!(Path.join(dir, "agents"))

    File.write!(
      Path.join([dir, "agents", "#{name}.md"]),
      "---\norg: #{org}\n#{front}---\nYou help.\n"
    )
  end

  defp token(org) when is_binary(org), do: token(Prefix.new!(org: org))

  defp token(prefix),
    do: %Wardrik.Token{
      principal: Wardrik.Principal.new(:user, "jon"),
      scope: [Wardrik.Role.bind([:owner], prefix)]
    }

  defp write_policy(%{dir: dir}, name, yaml) do
    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join([dir, "policies", "#{name}.yaml"]), yaml)
  end

  test "runs an agent for each file", %{org: org} = context do
    write(context, "alpha", "")
    write(context, "beta", "model: anthropic:claude-sonnet-5\n")

    Host.start_agents(context.dir)

    assert [{_alpha, {:ok, _}}, {_beta, {:ok, _}}] = Agents.files(Host.agents())

    assert Agent.status(AgentID.parse!("#{org}/beta"), host: Host.host()).model ==
             "anthropic:claude-sonnet-5"

    assert Enum.sort(
             Enum.map(
               Fleet.list(Prefix.parse!(org <> "/"), host: Host.host()),
               &to_string(&1.id)
             )
           ) == [
             "#{org}/alpha",
             "#{org}/beta"
           ]
  end

  test "reload/0 gives a running agent what its file says now", %{org: org} = context do
    write(context, "alpha", "")
    Host.start_agents(context.dir)
    {:ok, pid} = Fleet.spawn(AgentID.parse!("#{org}/alpha"))

    write(context, "alpha", "model: anthropic:claude-sonnet-5\n")
    Agents.reload(Host.agents())

    assert {:ok, ^pid} = Fleet.spawn(AgentID.parse!("#{org}/alpha"))

    assert Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host()).model ==
             "anthropic:claude-sonnet-5"
  end

  test "a file that does not read is reported, and the rest still run", %{org: org} = context do
    write(context, "alpha", "")
    write(context, "broken", "tools: [nope]\n")

    Host.start_agents(context.dir)

    assert [{_alpha, {:ok, _}}, {broken, {:error, message}}] = Agents.files(Host.agents())
    assert Path.basename(broken) == "broken.md"
    assert message =~ "names nope"
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())
    assert {:error, :not_found} = Agent.status(AgentID.parse!("#{org}/broken"), host: Host.host())
  end

  test "a file whose agent cannot be keyed is reported, and the rest still run", %{
    dir: dir,
    org: org
  } do
    write(%{dir: dir, org: org}, "alpha", "")
    write(%{dir: dir, org: "#{org}/eu"}, "slashed", "")

    Host.start_agents(dir)

    assert [{_alpha, {:ok, _}}, {slashed, {:error, message}}] = Agents.files(Host.agents())
    assert Path.basename(slashed) == "slashed.md"
    assert message =~ "slashed.md: an agent's org is"
    assert message =~ "which is not a segment"
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())
  end

  test "a file whose reading fails outright is reported, and the rest still run",
       %{org: org} = context do
    write(context, "alpha", "")
    write(context, "failing", "")

    stub(WardrikDaemon.AgentFile, :parse, fn context, path ->
      if Path.basename(path) == "failing.md",
        do: exit(:store_timeout),
        else: call_original(WardrikDaemon.AgentFile, :parse, [context, path])
    end)

    Host.start_agents(context.dir)

    assert [{_alpha, {:ok, _}}, {failing, {:error, message}}] = Agents.files(Host.agents())
    assert message == "#{failing}: (exit) :store_timeout"
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())
  end

  test "a policy in policies/ governs the agents that name it", %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    write(context, "alpha", "policy: careful\n")

    Host.start_agents(context.dir)

    assert [{_policy, {:ok, %WardrikPolicy{name: "careful"} = careful}}, {_alpha, {:ok, spec}}] =
             Agents.files(Host.agents())

    assert spec.hooks == WardrikPolicy.hooks(careful)
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())
  end

  test "an org's policy holds its agents ahead of their own", %{org: org} = context do
    write_policy(context, "team", "deny: [run_lua]\nbudget:\n  usd: 5.0\n")
    write_policy(context, "careful", "ask: [web_search]\nbudget:\n  tokens: 500\n")
    write(context, "alpha", "policy: careful\n")
    org_policy(org, "team")

    Host.start_agents(context.dir)

    assert [_team, _careful, {_alpha, {:ok, spec}}] = Agents.files(Host.agents())

    assert ["orgs/#{org}/team", "orgs/#{org}/team/budget", "careful", "careful/budget"] ==
             Enum.map(spec.hooks, & &1.name)

    alpha = AgentID.parse!("#{org}/alpha")

    assert WardrikDaemon.spent_by(spec, alpha) == [
             "orgs/#{org}/team: $0.00 of $5.00 today across #{org}",
             "careful: 0 of 500 tokens today"
           ]

    assert {:deny, _why} =
             WardrikPolicy.decide(hd(spec.hooks).value, "run_lua", [], %{})

    assert %{} = Agent.status(alpha, host: Host.host())
  end

  test "an org held to a policy policies/ does not hold runs none of its agents",
       %{org: org} = context do
    write(context, "alpha", "")
    org_policy(org, "nowhere")

    Host.start_agents(context.dir)

    assert [{_alpha, {:error, message}}] = Agents.files(Host.agents())

    assert message =~
             "config.yaml holds #{org}'s agents to the policy nowhere, which is not a policy in policies/"
  end

  defp org_policy(org, name) do
    own = Keyword.get(Host.sections(), WardrikDaemon, [])
    Host.put_section(WardrikDaemon, Keyword.put(own, :ceilings, %{org => name}))
  end

  test "notify started after it routes the agents its files route", %{org: org} = context do
    targets = [audit: {WardrikNotify.Webhook, url: "https://hooks.test"}]
    Host.put_section(WardrikNotify, targets: targets)
    notify = [routes: {Agents, :routes, [Host.agents()]}, targets: targets]

    write(context, "alpha", "notify: audit\n")
    Host.start_agents(context.dir)
    start_supervised!({WardrikNotify.Supervisor, notify})
    _files = Agents.files(Host.agents())

    alpha = AgentID.parse!("#{org}/alpha")
    assert %{^alpha => %WardrikNotify.Route{targets: [:audit]}} = Agents.routes(Host.agents())

    stop_supervised!(WardrikNotify.Supervisor)
    start_supervised!({WardrikNotify.Supervisor, notify})
    assert :sys.get_state(WardrikNotify.Dispatcher).routes == Agents.routes(Host.agents())
  end

  test "routes an agent the HTTP API defines as its definition says, until it is forgotten",
       %{org: org} = context do
    targets = [audit: {WardrikNotify.Webhook, url: "https://hooks.test"}]
    Host.put_section(WardrikNotify, targets: targets)
    notify = [routes: {Agents, :routes, [Host.agents()]}, targets: targets]
    Host.start_agents(context.dir)
    start_supervised!({WardrikNotify.Supervisor, notify})
    beta = AgentID.parse!("#{org}/beta")
    routes = fn -> :sys.get_state(WardrikNotify.Dispatcher).routes end

    assert {:ok, _spec} =
             Agents.put(Host.agents(), beta,
               definition: %{"notify" => "audit"},
               token: token(org)
             )

    assert %{^beta => %WardrikNotify.Route{targets: [:audit]}} = routes.()

    stop_supervised!(WardrikNotify.Supervisor)
    start_supervised!({WardrikNotify.Supervisor, notify})
    assert %{^beta => %WardrikNotify.Route{targets: [:audit]}} = routes.()

    assert {:ok, _spec} = Agents.put(Host.agents(), beta, definition: %{}, token: token(org))
    refute is_map_key(routes.(), beta)

    notify_on = %{"notify" => %{"to" => "audit", "on" => ["finished"]}}

    assert {:ok, _spec} =
             Agents.put(Host.agents(), beta, definition: notify_on, token: token(org))

    assert %{^beta => %WardrikNotify.Route{on: [:finished]}} = routes.()

    assert :ok = Agents.delete(Host.agents(), beta)
    refute is_map_key(routes.(), beta)
  end

  test "reads a definition sent to the HTTP API under the policies it read, and keeps it",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")

    assert {:ok, spec} =
             Agents.put(Host.agents(), defined,
               definition: %{"policy" => "careful"},
               token: token(org)
             )

    assert [%Wardrik.Hook{name: "careful", module: WardrikPolicy}] = spec.hooks

    assert Agents.get(Host.agents(), defined) ==
             {:ok, %Wardrik.Definition.Read{fields: %{"policy" => "careful"}, missing: []}}

    assert {:error, message} =
             Agents.put(Host.agents(), defined,
               definition: %{"policy" => "lax"},
               token: token(org)
             )

    assert message =~ "policy names lax"

    assert Agents.get(Host.agents(), defined) ==
             {:ok, %Wardrik.Definition.Read{fields: %{"policy" => "careful"}, missing: []}}

    assert Agents.delete(Host.agents(), defined) == :ok
    assert Agents.get(Host.agents(), defined) == {:error, :not_found}
    assert Agents.delete(Host.agents(), defined) == {:error, :not_found}
  end

  test "a definition names a server its owner has yet to add, and offers it once they do",
       %{org: org} = context do
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")
    owner = Prefix.new!(org: org)

    assert {:ok, spec} =
             Agents.put(Host.agents(), defined,
               definition: %{"tools" => ["crm/*"]},
               token: token(org)
             )

    assert Wardrik.LLM.Config.tools(spec.config) == []

    assert {:ok, %Wardrik.Definition.Read{missing: ["crm/*"]}} =
             Agents.get(Host.agents(), defined)

    remote = %WardrikMCP.Remote{
      key: Wardrik.Servers.Key.new(owner, "crm"),
      url: "https://mcp.crm.example/mcp",
      auth: %WardrikMCP.Auth.None{},
      filters: []
    }

    :ok = WardrikMCP.Remote.put(Wardrik.Host.store(Host.host()), remote)
    assert {:ok, %Wardrik.Definition.Read{missing: []}} = Agents.get(Host.agents(), defined)
  end

  test "a user's agent shares its org's tree where config.yaml shares it with them",
       %{org: org} = context do
    {:ok, share} = WardrikWorkspace.Share.new("#{org}/runbooks", read: ["#{org}/*"])
    Host.put_section(WardrikWorkspace, shared: [share])
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/@jon/defined")
    runbooks = %{"tree" => "#{org}/runbooks", "mode" => "read"}
    fields = %{"tools" => ["files"], "workspace" => %{"shared" => %{"runbooks" => runbooks}}}

    assert {:ok, _spec} =
             Agents.put(Host.agents(), defined,
               definition: fields,
               token: token(Prefix.new!(org: org, user: "jon"))
             )
  end

  test "a user's agent shares none of its org's trees", %{org: org} = context do
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/@jon/defined")
    fields = %{"tools" => ["files"], "workspace" => %{"shared" => %{"team" => org}}}

    assert {:error, message} =
             Agents.put(Host.agents(), defined, definition: fields, token: token(Prefix.all()))

    assert message ==
             "workspace shared team: #{org} belongs to #{org}/, which #{defined} is not under"
  end

  test "an agent the HTTP API defined is held to the policy its token names, which must be one",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    write_policy(context, "strict", "deny: [\"*\"]\n")
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")

    {:ok, _spec} =
      Agents.put(Host.agents(), defined,
        definition: %{"policy" => "careful"},
        token: %{token(org) | policy: "strict"}
      )

    assert {:ok, spec} = Agents.spec(Host.agents(), defined)
    assert [%{name: "policy/strict"}, %{name: "careful"}] = spec.hooks

    assert {:error, message} =
             Agents.put(Host.agents(), defined,
               definition: %{},
               token: %{token(org) | policy: "missing"}
             )

    assert message =~ "names the policy missing, which is not a policy in policies/"
  end

  test "a conversation runs on the definition of its agent, in the agent's tree",
       %{org: org} = context do
    write(context, "alpha", "model: anthropic:claude-haiku-4-5\ntools: [files]\n")
    Host.start_agents(context.dir)
    thread = AgentID.parse!("#{org}/alpha/1696.1234")

    assert {:ok, spec} = Agents.spec(Host.agents(), thread)
    assert spec.id == thread
    assert spec.config.model_spec == "anthropic:claude-haiku-4-5"
    assert [{WardrikWorkspace, workspace}] = spec.config.tools
    assert workspace.tree.tree == "agents/#{org}/alpha"
  end

  test "reload brings a conversation to its file, and leaves it where the file does not read",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    write(context, "alpha", "policy: careful\n")
    Host.start_agents(context.dir)
    thread = AgentID.parse!("#{org}/alpha/1696.1234")
    {:ok, options} = Agents.options(Host.agents(), thread)
    {:ok, _pid} = Fleet.spawn(thread, options)

    write(context, "alpha", "policy: lax\n")
    Agents.reload(Host.agents())

    assert [_policy, {_alpha, {:error, message}}] = Agents.files(Host.agents())
    assert message =~ "names lax"
    assert Agents.problems(Host.agents()) == []

    File.rm!(Path.join([context.dir, "policies", "careful.yaml"]))
    write(context, "alpha", "")
    Agents.reload(Host.agents())

    assert Agents.problems(Host.agents()) == []
    assert {:ok, %{hooks: []}} = Agents.spec(Host.agents(), thread)
  end

  test "reload brings the agents the HTTP API defined to what their definitions write now",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")

    {:ok, spec} =
      Agents.put(Host.agents(), defined, definition: %{"policy" => "careful"}, token: token(org))

    {:ok, _pid} = Fleet.put(spec)

    Agents.reload(Host.agents())
    assert Agents.problems(Host.agents()) == []

    File.rm!(Path.join([context.dir, "policies", "careful.yaml"]))
    Agents.reload(Host.agents())

    assert Agents.problems(Host.agents()) == [
             "#{defined} does not build from its definition: " <>
               "policy names careful, which is not a policy in policies/"
           ]

    :ok = Fleet.forget(defined)
    Agents.reload(Host.agents())

    assert Agents.problems(Host.agents()) == []
    assert {:ok, _definition} = Agents.get(Host.agents(), defined)
  end

  @tag :capture_log
  test "an agent the HTTP API defined starts from its definition once the store holds none",
       %{org: org} = context do
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")
    fails = %{"retries" => %{"attempts" => 0, "on_exhausted" => "fail"}}
    {:ok, spec} = Agents.put(Host.agents(), defined, definition: fails, grant: grant(org))
    {:ok, _pid} = Fleet.put(spec)

    # The store loses the agent, as a wiped one would, and keeps its definition.
    :ok = Fleet.forget(defined)
    Agents.reload(Host.agents())

    assert {:ok, _definition} = Agents.get(Host.agents(), defined)

    assert [%Fleet.Member{asleep: true}] =
             Fleet.list(Prefix.of(defined), host: Host.host())

    stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :offline} end)
    :ok = Event.Bus.subscribe(defined, level: :lifecycle)

    {:ok, _pid} =
      WardrikTrigger.put(defined, "tick",
        every: %WardrikTrigger.Interval{ms: 50},
        prompt: "Look."
      )

    assert_receive %Event{payload: %Event.TriggerFired{name: "tick", outcome: :asked}}, 2_000
    assert_receive %Event{payload: %Event.TurnFailed{}}, 2_000

    assert %Fleet.Member{asleep: false} =
             Fleet.lookup(defined, host: Host.host())
  end

  test "an agent starts with its file's options, or the defaults where no file declares it",
       %{org: org} = context do
    Host.put_section(Agents,
      defaults: %{"model" => "anthropic:claude-sonnet-5"}
    )

    write(context, "alpha", "model: anthropic:claude-haiku-4-5\n")
    Host.start_agents(context.dir)

    assert Agents.dir(Host.agents()) == context.dir
    assert {:ok, options} = Agents.options(Host.agents(), AgentID.parse!("#{org}/alpha"))
    assert options[:config].model_spec == "anthropic:claude-haiku-4-5"
    assert {:ok, options} = Agents.options(Host.agents(), AgentID.parse!("#{org}/@jon/assistant"))
    assert options[:config].model_spec == "anthropic:claude-sonnet-5"

    Host.put_section(Agents, defaults: %{"tools" => ["nothing"]})
    assert {:error, message} = Agents.options(Host.agents(), AgentID.parse!("#{org}/assistant"))
    assert message =~ "tools names nothing"
  end

  test "leaves an agent a file declares to its file", %{org: org} = context do
    write(context, "alpha", "")
    Host.start_agents(context.dir)

    message =
      "#{org}/alpha is declared by agents/alpha.md; change or remove that file, then wardrik reload reads it"

    assert Agents.put(Host.agents(), AgentID.parse!("#{org}/alpha"),
             definition: %{},
             token: token(org)
           ) ==
             {:error, :conflict, message}

    assert Agents.delete(Host.agents(), AgentID.parse!("#{org}/alpha")) ==
             {:error, :conflict, message}

    assert Agents.editable(Host.agents(), AgentID.parse!("#{org}/alpha")) ==
             {:error, :conflict, message}

    assert Agents.put_trigger(Host.agents(), AgentID.parse!("#{org}/alpha"), "sweep", fields: %{}) ==
             {:error, :conflict, message}

    assert Agents.delete_trigger(Host.agents(), AgentID.parse!("#{org}/alpha"), "sweep") ==
             {:error, :conflict, message}
  end

  test "answers what it last read while it is busy reading again", %{org: org} = context do
    write(context, "alpha", "")
    write_policy(context, "careful", "deny: [run_lua]\n")
    Host.start_agents(context.dir)
    assert [_policy, _agent] = Agents.files(Host.agents())

    :ok = :sys.suspend(Agents)
    on_exit(fn -> if Process.whereis(Agents), do: :sys.resume(Agents) end)

    assert [{_careful, {:ok, %WardrikPolicy{}}}, {_alpha, {:ok, _spec}}] =
             Agents.files(Host.agents())

    assert Agents.dir(Host.agents()) == context.dir
    assert Agents.problems(Host.agents()) == []

    assert {:error, :conflict, _message} =
             Agents.editable(Host.agents(), AgentID.parse!("#{org}/alpha"))

    assert Agents.editable(Host.agents(), AgentID.parse!("#{org}/beta")) == :ok
    assert {:ok, _spec} = Agents.spec(Host.agents(), AgentID.parse!("#{org}/alpha"))

    :ok = :sys.resume(Agents)
  end

  describe "an agent asleep" do
    test "is left asleep by a reload, and wakes with its file as it reads now",
         %{org: org} = context do
      write(context, "alpha", "idle_timeout: 1\nmodel: anthropic:claude-sonnet-5\n")
      Host.start_agents(context.dir)
      Agents.files(Host.agents())
      key = AgentID.parse!("#{org}/alpha")
      :ok = Wardrik.Event.Bus.subscribe(key)
      assert_receive %Wardrik.Event{payload: %Event.AgentStopped{reason: :idle}}, 3_000
      assert Wardrik.Test.Fleet.await_update(fn -> Fleet.held_pid(key, wake: false) == nil end)

      write(context, "alpha", "idle_timeout: 1\nmodel: anthropic:claude-haiku-4-5\n")
      Agents.reload(Host.agents())

      assert Fleet.held_pid(key, wake: false) == nil
      assert %{model: "anthropic:claude-haiku-4-5"} = Agent.status(key, host: Host.host())
    end
  end

  describe "an agent the files no longer declare" do
    test "stops once its file is gone, and comes back as it was with the file",
         %{dir: dir, org: org} = context do
      write(context, "alpha", "")
      write(context, "beta", "triggers:\n  name: sweep\n  every: 1h\n  prompt: Look.\n")
      Host.start_agents(dir)
      Agents.files(Host.agents())
      %{generation: generation} = Agent.snapshot(AgentID.parse!("#{org}/beta"), host: Host.host())

      File.rm!(Path.join([dir, "agents", "beta.md"]))
      Agents.reload(Host.agents())

      assert Fleet.held_pid(AgentID.parse!("#{org}/beta"), wake: false) == nil
      assert WardrikTrigger.for_agent(AgentID.parse!("#{org}/beta")) == []
      assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())

      write(context, "beta", "")
      Agents.reload(Host.agents())

      assert %{generation: ^generation} =
               Agent.snapshot(AgentID.parse!("#{org}/beta"), host: Host.host())
    end

    test "stops when its file names another agent", %{org: org} = context do
      write(context, "alpha", "")
      Host.start_agents(context.dir)

      write(context, "alpha", "name: gamma\n")
      Agents.reload(Host.agents())

      assert Fleet.held_pid(AgentID.parse!("#{org}/alpha"), wake: false) == nil
      assert %{} = Agent.status(AgentID.parse!("#{org}/gamma"), host: Host.host())
    end

    test "runs on while another node's files declare it", %{dir: dir, org: org} = context do
      other = :"agents-test@elsewhere"
      write(context, "beta", "")
      agents = %{Host.agents(dir) | nodes: fn -> [other] end}
      start_supervised!({Agents, agents: agents, host: Host.host()})
      Agents.files(agents)

      {:ok, _vsn} =
        WardrikStore.put(store(), :declared, "agents/#{other}", %{"#{org}/beta" => "beta.md"})

      on_exit(fn -> WardrikStore.delete(store(), :declared, "agents/#{other}") end)

      File.rm!(Path.join([dir, "agents", "beta.md"]))
      Agents.reload(agents)

      assert %{} = Agent.status(AgentID.parse!("#{org}/beta"), host: Host.host())

      assert Agents.editable(agents, AgentID.parse!("#{org}/beta")) ==
               {:error, :conflict,
                "#{org}/beta is declared by agents/beta.md on #{other}; change or remove that file, then wardrik reload reads it"}
    end

    test "is left as it was while its file does not read", %{org: org} = context do
      write(context, "alpha", "")
      Host.start_agents(context.dir)

      write(context, "alpha", "tools: [nope]\n")
      Agents.reload(Host.agents())
      assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())

      write(context, "alpha", "")
      Agents.reload(Host.agents())
      assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())
    end

    test "leaves an agent the HTTP API defined alone", %{org: org} = context do
      write(context, "alpha", "")
      Host.start_agents(context.dir)

      {:ok, spec} =
        Agents.put(Host.agents(), AgentID.parse!("#{org}/defined"),
          definition: %{"instructions" => "You help."},
          token: token(org)
        )

      {:ok, _pid} = Fleet.put(spec)

      File.rm!(Path.join([context.dir, "agents", "alpha.md"]))
      Agents.reload(Host.agents())

      assert Fleet.held_pid(AgentID.parse!("#{org}/alpha"), wake: false) == nil
      assert %{} = Agent.status(AgentID.parse!("#{org}/defined"), host: Host.host())
      assert :ok = Agents.editable(Host.agents(), AgentID.parse!("#{org}/defined"))
    end
  end

  test "an agent naming a policy that does not read does not run", %{org: org} = context do
    write_policy(context, "careful", "deny: run_lua\n")
    write(context, "alpha", "policy: careful\n")

    Host.start_agents(context.dir)

    assert [{_policy, {:error, policy_error}}, {_alpha, {:error, agent_error}}] =
             Agents.files(Host.agents())

    assert policy_error =~ "careful.yaml: deny is a list"
    assert agent_error =~ "names careful"
    assert Fleet.held_pid(AgentID.parse!("#{org}/alpha"), wake: false) == nil
  end

  test "runs the triggers a file declares, and stops those it no longer does",
       %{org: org} = context do
    write(context, "alpha", "triggers:\n  name: sweep\n  every: 1h\n  prompt: Look.\n")
    Host.start_agents(context.dir)
    assert [{_alpha, {:ok, _spec}}] = Agents.files(Host.agents())

    assert [%WardrikTrigger.Status{name: "sweep"}] =
             WardrikTrigger.for_agent(AgentID.parse!("#{org}/alpha"))

    assert WardrikDaemon.status(Host.host(Host.agents()), Host.config(context.dir)) =~
             ~r"#{org}/alpha .*next run in 5\dm"

    write(context, "alpha", "")
    Agents.reload(Host.agents())

    assert WardrikTrigger.for_agent(AgentID.parse!("#{org}/alpha")) == []
  end

  test "reads a policy written as .yml, and reports a second file of the same name",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    File.write!(Path.join([context.dir, "policies", "careful.yml"]), "default: allow\n")
    File.write!(Path.join([context.dir, "policies", "strict.yml"]), "default: deny\n")
    write(context, "alpha", "policy: strict\n")

    Host.start_agents(context.dir)

    assert [
             {careful_yaml, {:ok, %WardrikPolicy{name: "careful"}}},
             {careful_yml, {:error, message}},
             {_strict, {:ok, %WardrikPolicy{name: "strict"}}},
             {_alpha, {:ok, _spec}}
           ] = Agents.files(Host.agents())

    assert Path.basename(careful_yaml) == "careful.yaml"
    assert message == "#{careful_yml}: policy careful is already careful.yaml"
    assert [_member] = Fleet.list(Prefix.parse!(org <> "/"), host: Host.host())
  end

  # The installation of the channel `channel`, as a room's events find it.
  defp in_channel(channel),
    do: %WardrikChannel.Installation{
      channel: channel,
      workspace: channel,
      owner: Prefix.all(),
      token: "token"
    }

  test "offers in a channel the agents whose files name it, of the orgs it serves",
       %{org: org} = context do
    Host.put_section(WardrikChannel, orgs: [slack: [org], everyone: :all])

    write(context, "books", "channels: [slack]\n")
    write(context, "triage", "channels: [slack, everyone]\n")
    write(context, "quiet", "")
    Host.start_agents(context.dir)
    # Answered once the files have been read.
    _files = Agents.files(Host.agents())

    assert Enum.map(Agents.offered(Host.agents(), in_channel("slack")), & &1.agent) ==
             [AgentID.parse!("#{org}/books"), AgentID.parse!("#{org}/triage")]

    everyone = Enum.map(Agents.offered(Host.agents(), in_channel("everyone")), & &1.agent)
    assert AgentID.parse!("#{org}/triage") in everyone
    refute AgentID.parse!("#{org}/books") in everyone

    Host.put_section(WardrikChannel, orgs: [slack: ["elsewhere"]])
    assert Agents.offered(Host.agents(), in_channel("slack")) == []
    assert Agents.offered(Host.agents(), in_channel("nowhere")) == []
  end

  test "creates an agent for a room from the defaults, where they name a policy and the channel lets it",
       %{org: org} = context do
    Host.put_section(WardrikChannel,
      orgs: [slack: [org], closed: [org]],
      creates: [slack: true, closed: false]
    )

    Host.put_section(Agents,
      defaults: %{"model" => "anthropic:claude-sonnet-5"}
    )

    write_policy(context, "careful", "deny: [run_lua]\n")
    Host.start_agents(context.dir)
    _files = Agents.files(Host.agents())
    maria = Wardrik.Principal.new(:channel, "slack/T1/U1", name: "maria")

    refute Agents.creatable?(Host.agents(), in_channel("slack"))

    assert {:error, "Agents are not created from here" <> _} =
             Agents.create_in(Host.agents(), in_channel("slack"), "books", maria)

    Host.put_section(Agents,
      defaults: %{"model" => "anthropic:claude-sonnet-5", "policy" => "careful"}
    )

    assert Agents.creatable?(Host.agents(), in_channel("slack"))
    refute Agents.creatable?(Host.agents(), in_channel("closed"))

    assert {:ok, %WardrikChannel.Offer{agent: id, description: "Answers in #Books & Bills."}} =
             Agents.create_in(Host.agents(), in_channel("slack"), "Books & Bills", maria)

    assert id == AgentID.parse!("#{org}/books-bills")
    assert Fleet.lookup(id, host: Host.host())
    assert id in Enum.map(Agents.offered(Host.agents(), in_channel("slack")), & &1.agent)

    assert Wardrik.Test.Audit.about("agents/#{id}") ==
             [{"agent.defined", %{"type" => "channel", "id" => "slack/T1/U1", "name" => "maria"}}]

    assert {:error, message} =
             Agents.create_in(Host.agents(), in_channel("slack"), "books-bills", maria)

    assert message =~ "#{org}/books-bills is there already"

    assert {:error, "Agents are not created from here" <> _} =
             Agents.create_in(Host.agents(), in_channel("closed"), "x", maria)

    assert {:error, ~s("!!!" makes no agent's name.)} =
             Agents.create_in(Host.agents(), in_channel("slack"), "!!!", maria)
  end

  test "says in a channel how an agent is offered there, and who else decides" do
    assert Agents.offering(in_channel("slack")) ==
             "Whoever runs Wardrik can offer an agent here by adding `channels: [slack]` to its agent file."

    assert Agents.deciding(in_channel("slack")) =~ "approvers in config.yaml"
  end

  test "starts the agent of a room's thread on its definition, and names the channel's approvers",
       %{org: org} = context do
    Host.put_section(WardrikChannel,
      orgs: [slack: [org]],
      approvers: [slack: %WardrikChannel.Approvers.Named{names: ["@maria"]}]
    )

    write(context, "books", "channels: [slack]\ndescription: Keeps the books.\n")
    Host.start_agents(context.dir)
    _files = Agents.files(Host.agents())

    thread = AgentID.put_external_id(AgentID.parse!("#{org}/books"), "C1-1.1")
    assert {:ok, pid} = Agents.start(Host.agents(), in_channel("slack"), thread)
    assert Fleet.whereis(thread, host: Host.host()) == pid
    assert Agents.start(Host.agents(), in_channel("slack"), thread) == {:ok, pid}

    assert Agent.status(thread, host: Host.host()).model ==
             Agent.status(AgentID.parse!("#{org}/books"), host: Host.host()).model

    assert Agents.approvers(Host.agents(), in_channel("slack")) ==
             %WardrikChannel.Approvers.Named{names: ["@maria"]}

    assert Agents.approvers(Host.agents(), in_channel("other")) ==
             %WardrikChannel.Approvers.Named{names: []}

    Host.put_section(WardrikChannel,
      orgs: [slack: [org]],
      approvers: [slack: %WardrikChannel.Approvers.Anyone{}]
    )

    assert Agents.approvers(Host.agents(), in_channel("slack")) ==
             %WardrikChannel.Approvers.Anyone{}
  end

  test "no agents/ at all runs nothing", %{tmp_dir: dir} do
    Host.start_agents(Path.join(dir, "missing"))
    assert Agents.files(Host.agents()) == []
  end
end
