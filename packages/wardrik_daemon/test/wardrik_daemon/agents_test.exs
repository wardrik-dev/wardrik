defmodule WardrikDaemon.AgentsTest do
  use ExUnit.Case, async: false

  use Mimic

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.Resource
  alias WardrikDaemon.Agents
  alias WardrikDaemon.Test.Host

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup %{tmp_dir: dir} do
    org = "agents-#{System.unique_integer([:positive])}"
    Host.declare([org, "acme"])

    on_exit(fn ->
      own = Resource.parse!(org <> "/*")

      for trigger <- WardrikTrigger.list(own),
          do: WardrikTrigger.delete(trigger.agent, trigger.name)

      Fleet.forget_under(own)
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

  defp token(org) when is_binary(org), do: token(Resource.parse!(org <> "/agent/*"))

  defp token(pattern),
    do: %Wardrik.Token{
      principal: Wardrik.Principal.new(:user, "jon"),
      scope: [Wardrik.Role.bind([:owner], [pattern])]
    }

  defp definitions, do: Agents.definitions(Host.agents())

  # Reads `fields` as the definition the HTTP API was sent for `id` with
  # `token`, keeps it, and answers the spec it writes.
  defp put(id, fields, token) do
    with {:ok, definition} <-
           Definition.read(fields,
             id: id,
             source: {:api, token},
             context: Agents.context(Host.agents())
           ),
         :ok <- Definitions.put(definitions(), definition),
         do: Definitions.spec(definitions(), id, host: Host.host())
  end

  # Why each of the test's files, definitions or agents did not read or
  # build, as a reload of every definition in the suite's store answers it.
  defp failed(%{org: org, dir: dir}, %{failed: failed}),
    do:
      Enum.filter(failed, &(String.starts_with?(&1, org <> "/") or String.starts_with?(&1, dir)))

  defp write_policy(%{dir: dir}, name, yaml) do
    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join([dir, "policies", "#{name}.yaml"]), yaml)
  end

  test "runs an agent for each file", %{org: org} = context do
    write(context, "alpha", "")
    write(context, "beta", "model: anthropic:claude-sonnet-5\n")

    Host.start_agents(context.dir)

    assert [{_alpha, {:ok, _}}, {_beta, {:ok, _}}] =
             Agents.files(Host.agents(), host: Host.host())

    assert Agent.status(AgentID.parse!("#{org}/beta"), host: Host.host()).model ==
             "anthropic:claude-sonnet-5"

    assert Enum.sort(
             Enum.map(
               Fleet.list(Resource.parse!(org <> "/agent/*"), host: Host.host()),
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
    Host.reload()

    assert {:ok, ^pid} = Fleet.spawn(AgentID.parse!("#{org}/alpha"))

    assert Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host()).model ==
             "anthropic:claude-sonnet-5"
  end

  test "a file that does not read is reported, and the rest still run", %{org: org} = context do
    write(context, "alpha", "")
    write(context, "broken", "tools: [nope]\n")

    Host.start_agents(context.dir)

    assert [{_alpha, {:ok, _}}, {broken, {:error, message}}] =
             Agents.files(Host.agents(), host: Host.host())

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

    assert [{_alpha, {:ok, _}}, {slashed, {:error, message}}] =
             Agents.files(Host.agents(), host: Host.host())

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

    assert [{_alpha, {:ok, _}}, {failing, {:error, message}}] =
             Agents.files(Host.agents(), host: Host.host())

    assert message == "#{failing}: (exit) :store_timeout"
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())
  end

  test "a policy in policies/ governs the agents that name it", %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    write(context, "alpha", "policy: careful\n")

    Host.start_agents(context.dir)

    assert [{_policy, {:ok, %WardrikPolicy{name: "careful"} = careful}}, {_alpha, {:ok, spec}}] =
             Agents.files(Host.agents(), host: Host.host())

    assert spec.hooks == WardrikPolicy.hooks(careful)
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())
  end

  test "an org's policy holds its agents ahead of their own", %{org: org} = context do
    write_policy(context, "team", "deny: [run_lua]\nbudget:\n  usd: 5.0\n")
    write_policy(context, "careful", "ask: [web_search]\nbudget:\n  tokens: 500\n")
    write(context, "alpha", "policy: careful\n")
    org_policy(org, "team")

    Host.start_agents(context.dir)

    assert [_team, _careful, {_alpha, {:ok, spec}}] =
             Agents.files(Host.agents(), host: Host.host())

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

    assert [{_alpha, {:error, message}}] = Agents.files(Host.agents(), host: Host.host())

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
    notify = [routes: {Definitions, :routes, [definitions()]}, targets: targets]

    write(context, "alpha", "notify: audit\n")
    Host.start_agents(context.dir)
    start_supervised!({WardrikNotify.Supervisor, notify})
    _files = Agents.files(Host.agents(), host: Host.host())

    alpha = AgentID.parse!("#{org}/alpha")

    assert %{^alpha => %WardrikNotify.Route{targets: ["audit"]}} =
             Definitions.routes(definitions())

    stop_supervised!(WardrikNotify.Supervisor)
    start_supervised!({WardrikNotify.Supervisor, notify})
    assert :sys.get_state(WardrikNotify.Dispatcher).routes == Definitions.routes(definitions())
  end

  test "routes an agent the HTTP API defines as its definition says, until it is forgotten",
       %{org: org} = context do
    targets = [audit: {WardrikNotify.Webhook, url: "https://hooks.test"}]
    Host.put_section(WardrikNotify, targets: targets)
    notify = [routes: {Definitions, :routes, [definitions()]}, targets: targets]
    Host.start_agents(context.dir)
    start_supervised!({WardrikNotify.Supervisor, notify})
    beta = AgentID.parse!("#{org}/beta")
    routes = fn -> :sys.get_state(WardrikNotify.Dispatcher).routes end

    assert {:ok, _spec} =
             put(beta, %{"notify" => "audit"}, token(org))

    assert %{^beta => %WardrikNotify.Route{targets: ["audit"]}} = routes.()

    stop_supervised!(WardrikNotify.Supervisor)
    start_supervised!({WardrikNotify.Supervisor, notify})
    assert %{^beta => %WardrikNotify.Route{targets: ["audit"]}} = routes.()

    assert {:ok, _spec} = put(beta, %{}, token(org))
    refute is_map_key(routes.(), beta)

    notify_on = %{"notify" => %{"to" => "audit", "on" => ["finished"]}}

    assert {:ok, _spec} =
             put(beta, notify_on, token(org))

    assert %{^beta => %WardrikNotify.Route{on: [:finished]}} = routes.()

    assert :ok = Definitions.delete(definitions(), beta)
    refute is_map_key(routes.(), beta)
  end

  test "reads a definition sent to the HTTP API under the policies it read, and keeps it",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")

    assert {:ok, spec} =
             put(defined, %{"policy" => "careful"}, token(org))

    assert [%Wardrik.Hook{name: "careful", module: WardrikPolicy}] = spec.hooks

    assert {:ok, %Definition{fields: %{"policy" => "careful"}}} =
             Definitions.get(definitions(), defined)

    assert {:error, message} =
             put(defined, %{"policy" => "lax"}, token(org))

    assert message =~ "policy names lax"

    assert {:ok, %Definition{fields: %{"policy" => "careful"}}} =
             Definitions.get(definitions(), defined)

    assert Definitions.delete(definitions(), defined) == :ok
    assert Definitions.get(definitions(), defined) == {:error, :not_found}
    assert Definitions.delete(definitions(), defined) == {:error, :not_found}
  end

  test "a definition names a server its owner has yet to add, and offers it once they do",
       %{org: org} = context do
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")
    owner = Wardrik.Resource.parse!(org)

    assert {:ok, spec} =
             put(defined, %{"tools" => ["crm/*"]}, token(org))

    assert Wardrik.LLM.Config.tools(spec.config) == []

    assert {:ok, definition} = Definitions.get(definitions(), defined)
    assert Definition.missing(definition, host: Host.host()) == ["crm/*"]

    remote = %WardrikMCP.Remote{
      key: Wardrik.Resource.new(owner, server: "crm"),
      url: "https://mcp.crm.example/mcp",
      auth: %WardrikMCP.Auth.None{},
      filters: []
    }

    :ok = WardrikMCP.Remote.put(Wardrik.Host.store(Host.host()), remote)
    assert Definition.missing(definition, host: Host.host()) == []
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
             put(defined, fields, token(Resource.parse!(org <> "/@jon/agent/*")))
  end

  test "a user's agent shares none of its org's trees", %{org: org} = context do
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/@jon/defined")
    fields = %{"tools" => ["files"], "workspace" => %{"shared" => %{"team" => org}}}

    assert {:error, message} =
             put(defined, fields, token(Resource.parse!("*")))

    assert message ==
             "workspace shared team: #{org} belongs to #{org}/agent/*, which does not cover #{defined}"
  end

  test "an agent the HTTP API defined is held to the policy its token names, which must be one",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    write_policy(context, "strict", "deny: [\"*\"]\n")
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")

    {:ok, _spec} =
      put(defined, %{"policy" => "careful"}, %{token(org) | policy: "strict"})

    assert {:ok, spec} = Agents.spec(Host.agents(), defined, host: Host.host())
    assert [%{name: "policy/strict"}, %{name: "careful"}] = spec.hooks

    assert {:error, message} =
             put(defined, %{}, %{token(org) | policy: "missing"})

    assert message =~ "names the policy missing, which is not a policy in policies/"
  end

  test "a conversation runs on the definition of its agent, in the agent's tree",
       %{org: org} = context do
    write(context, "alpha", "model: anthropic:claude-haiku-4-5\ntools: [files]\n")
    Host.start_agents(context.dir)
    thread = AgentID.parse!("#{org}/alpha/1696.1234")

    assert {:ok, spec} = Agents.spec(Host.agents(), thread, host: Host.host())
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
    {:ok, spec} = Agents.spec(Host.agents(), thread, host: Host.host())
    {:ok, _pid} = Fleet.spawn(thread, Wardrik.Agent.Spec.options(spec))

    write(context, "alpha", "policy: lax\n")
    assert [message] = failed(context, Host.reload())
    assert message =~ "names lax"

    assert [_policy, {_alpha, {:error, ^message}}] =
             Agents.files(Host.agents(), host: Host.host())

    File.rm!(Path.join([context.dir, "policies", "careful.yaml"]))
    write(context, "alpha", "")
    assert failed(context, Host.reload()) == []
    assert {:ok, %{hooks: []}} = Agents.spec(Host.agents(), thread, host: Host.host())
  end

  test "reload brings the agents the HTTP API defined to what their definitions write now",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")

    {:ok, spec} =
      put(defined, %{"policy" => "careful"}, token(org))

    {:ok, _pid} = Fleet.put(spec)

    assert %{reloaded: reloaded} = Host.reload()
    assert defined in reloaded

    File.rm!(Path.join([context.dir, "policies", "careful.yaml"]))

    missing = "policy names careful, which is not a policy in policies/"

    assert failed(context, Host.reload()) == [
             "#{defined} does not read: #{missing}",
             "#{defined} does not build from its definition: #{missing}"
           ]

    :ok = Fleet.forget(defined)
    assert failed(context, Host.reload()) == ["#{defined} does not read: #{missing}"]
    assert {:ok, _definition} = Definitions.get(definitions(), defined)
  end

  @tag :capture_log
  test "an agent the HTTP API defined starts from its definition once the store holds none",
       %{org: org} = context do
    Host.start_agents(context.dir)
    defined = AgentID.parse!("#{org}/defined")
    fails = %{"retries" => %{"attempts" => 0, "on_exhausted" => "fail"}}
    {:ok, spec} = put(defined, fails, token(org))
    {:ok, _pid} = Fleet.put(spec)

    # The store loses the agent, as a wiped one would, and keeps its definition.
    :ok = Fleet.forget(defined)
    Host.reload()

    assert {:ok, _definition} = Definitions.get(definitions(), defined)

    assert [%Fleet.Member{asleep: true}] =
             Fleet.list(AgentID.resource(defined), host: Host.host())

    Wardrik.Test.LLM.answering(Wardrik.Test.llm(), fn _asked ->
      %Wardrik.LLM.Error{message: "offline"}
    end)

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

    assert {:ok, spec} =
             Agents.spec(Host.agents(), AgentID.parse!("#{org}/alpha"), host: Host.host())

    assert spec.config.model_spec == "anthropic:claude-haiku-4-5"

    assert {:ok, spec} =
             Agents.spec(Host.agents(), AgentID.parse!("#{org}/@jon/assistant"),
               host: Host.host()
             )

    assert spec.config.model_spec == "anthropic:claude-sonnet-5"

    Host.put_section(Agents, defaults: %{"tools" => ["nothing"]})

    assert {:error, message} =
             Agents.spec(Host.agents(), AgentID.parse!("#{org}/assistant"), host: Host.host())

    assert message =~ "tools names nothing"
  end

  test "leaves an agent a file declares to its file", %{org: org} = context do
    write(context, "alpha", "")
    Host.start_agents(context.dir)

    alpha = AgentID.parse!("#{org}/alpha")

    message =
      "#{alpha} is declared by agents/alpha.md; change or remove that file, then reload it"

    assert put(alpha, %{}, token(org)) == {:error, :conflict, message}
    assert Definitions.editable(definitions(), alpha) == {:error, :conflict, message}

    assert Definitions.put_trigger(definitions(), alpha, "sweep", %{}) ==
             {:error, :conflict, message}

    assert Definitions.delete_trigger(definitions(), alpha, "sweep") ==
             {:error, :conflict, message}
  end

  describe "an agent asleep" do
    test "is left asleep by a reload, and wakes with its file as it reads now",
         %{org: org} = context do
      write(context, "alpha", "idle_timeout: 1\nmodel: anthropic:claude-sonnet-5\n")
      Host.start_agents(context.dir)
      key = AgentID.parse!("#{org}/alpha")
      :ok = Wardrik.Event.Bus.subscribe(key)
      assert %{} = Agent.status(key, host: Host.host())
      assert_receive %Wardrik.Event{payload: %Event.AgentStopped{reason: :idle}}, 3_000
      assert Wardrik.Test.Fleet.await_update(fn -> Fleet.held_pid(key, wake: false) == nil end)

      write(context, "alpha", "idle_timeout: 1\nmodel: anthropic:claude-haiku-4-5\n")
      Host.reload()

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
      Agents.files(Host.agents(), host: Host.host())
      %{generation: generation} = Agent.snapshot(AgentID.parse!("#{org}/beta"), host: Host.host())

      File.rm!(Path.join([dir, "agents", "beta.md"]))
      Host.reload()

      assert Fleet.held_pid(AgentID.parse!("#{org}/beta"), wake: false) == nil
      assert WardrikTrigger.for_agent(AgentID.parse!("#{org}/beta")) == []
      assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())

      write(context, "beta", "")
      Host.reload()

      assert %{generation: ^generation} =
               Agent.snapshot(AgentID.parse!("#{org}/beta"), host: Host.host())
    end

    test "stops when its file names another agent", %{org: org} = context do
      write(context, "alpha", "")
      Host.start_agents(context.dir)

      write(context, "alpha", "name: gamma\n")
      Host.reload()

      assert Fleet.held_pid(AgentID.parse!("#{org}/alpha"), wake: false) == nil
      assert %{} = Agent.status(AgentID.parse!("#{org}/gamma"), host: Host.host())
    end

    test "is left as it was while its file does not read", %{org: org} = context do
      write(context, "alpha", "")
      Host.start_agents(context.dir)

      write(context, "alpha", "tools: [nope]\n")
      Host.reload()
      assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())

      write(context, "alpha", "")
      Host.reload()
      assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"), host: Host.host())
    end

    test "leaves an agent the HTTP API defined alone", %{org: org} = context do
      write(context, "alpha", "")
      Host.start_agents(context.dir)

      {:ok, spec} =
        put(AgentID.parse!("#{org}/defined"), %{"instructions" => "You help."}, token(org))

      {:ok, _pid} = Fleet.put(spec)

      File.rm!(Path.join([context.dir, "agents", "alpha.md"]))
      Host.reload()

      assert Fleet.held_pid(AgentID.parse!("#{org}/alpha"), wake: false) == nil
      assert %{} = Agent.status(AgentID.parse!("#{org}/defined"), host: Host.host())
      assert :ok = Definitions.editable(definitions(), AgentID.parse!("#{org}/defined"))
    end
  end

  test "an agent naming a policy that does not read does not run", %{org: org} = context do
    write_policy(context, "careful", "deny: run_lua\n")
    write(context, "alpha", "policy: careful\n")

    Host.start_agents(context.dir)

    assert [{_policy, {:error, policy_error}}, {_alpha, {:error, agent_error}}] =
             Agents.files(Host.agents(), host: Host.host())

    assert policy_error =~ "careful.yaml: deny is a list"
    assert agent_error =~ "names careful"
    assert Fleet.held_pid(AgentID.parse!("#{org}/alpha"), wake: false) == nil
  end

  test "runs the triggers a file declares, and stops those it no longer does",
       %{org: org} = context do
    write(context, "alpha", "triggers:\n  name: sweep\n  every: 1h\n  prompt: Look.\n")
    Host.start_agents(context.dir)
    assert [{_alpha, {:ok, _spec}}] = Agents.files(Host.agents(), host: Host.host())

    assert [%WardrikTrigger.Status{name: "sweep"}] =
             WardrikTrigger.for_agent(AgentID.parse!("#{org}/alpha"))

    assert WardrikDaemon.status(Host.host(Host.agents()), Host.config(context.dir)) =~
             ~r"#{org}/alpha .*next run in 5\dm"

    write(context, "alpha", "")
    Host.reload()

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
           ] = Agents.files(Host.agents(), host: Host.host())

    assert Path.basename(careful_yaml) == "careful.yaml"
    assert message == "#{careful_yml}: policy careful is already careful.yaml"
    assert [_member] = Fleet.list(Resource.parse!(org <> "/agent/*"), host: Host.host())
  end

  test "a room's thread starts on its agent's definition, in a channel config.yaml offers it in",
       %{org: org} = context do
    Host.put_section(WardrikChannel, orgs: [slack: [org]])
    write(context, "books", "channels: [slack]\ndescription: Keeps the books.\n")
    Host.start_agents(context.dir)
    _files = Agents.files(Host.agents(), host: Host.host())

    %{"slack" => channel} =
      WardrikChannel.channels(
        [
          channels: [slack: {WardrikDaemon.Test.Channel, []}],
          installations:
            WardrikChannel.Installations.Config.new([{:slack, "token", Resource.deployment()}]),
          orgs: [slack: [org]]
        ],
        host: Host.host(Host.agents())
      )

    {:ok, workspace} = WardrikChannel.Workspace.new(channel.context, "slack")
    books = AgentID.parse!("#{org}/books")
    assert [%WardrikChannel.Offer{agent: ^books}] = WardrikChannel.Workspace.offered(workspace)

    thread = AgentID.put_external_id(books, "C1-1.1")
    assert {:ok, pid} = WardrikChannel.Workspace.start(workspace, thread)
    assert Fleet.whereis(thread, host: Host.host()) == pid

    assert Agent.status(thread, host: Host.host()).model ==
             Agent.status(books, host: Host.host()).model
  end

  test "no agents/ at all runs nothing", %{tmp_dir: dir} do
    Host.start_agents(Path.join(dir, "missing"))
    assert Agents.files(Host.agents(), host: Host.host()) == []
  end
end
