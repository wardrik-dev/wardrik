defmodule WardrikDaemon.AgentsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias WardrikDaemon.Agents

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup %{tmp_dir: dir} do
    org = "agents-#{System.unique_integer([:positive])}"

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

  defp grant(org) when is_binary(org), do: grant(Prefix.new!(org: org))

  defp grant(scope) do
    {:ok, grant} = Wardrik.Grant.new(scope)
    grant
  end

  defp write_policy(%{dir: dir}, name, yaml) do
    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join([dir, "policies", "#{name}.yaml"]), yaml)
  end

  test "runs an agent for each file", %{org: org} = context do
    write(context, "alpha", "")
    write(context, "beta", "model: anthropic:claude-sonnet-5\n")

    start_supervised!({Agents, dir: context.dir})

    assert [{_alpha, {:ok, _}}, {_beta, {:ok, _}}] = Agents.files()

    assert Agent.status(AgentID.parse!("#{org}/beta")).model ==
             "anthropic:claude-sonnet-5"

    assert Enum.sort(Enum.map(Fleet.list(Prefix.parse!(org <> "/")), &to_string(&1.id))) == [
             "#{org}/alpha",
             "#{org}/beta"
           ]
  end

  test "reload/0 gives a running agent what its file says now", %{org: org} = context do
    write(context, "alpha", "")
    start_supervised!({Agents, dir: context.dir})
    {:ok, pid} = Fleet.spawn(AgentID.parse!("#{org}/alpha"))

    write(context, "alpha", "model: anthropic:claude-sonnet-5\n")
    Agents.reload()

    assert {:ok, ^pid} = Fleet.spawn(AgentID.parse!("#{org}/alpha"))

    assert Agent.status(AgentID.parse!("#{org}/alpha")).model ==
             "anthropic:claude-sonnet-5"
  end

  test "a file that does not read is reported, and the rest still run", %{org: org} = context do
    write(context, "alpha", "")
    write(context, "broken", "tools: [nope]\n")

    start_supervised!({Agents, dir: context.dir})

    assert [{_alpha, {:ok, _}}, {broken, {:error, message}}] = Agents.files()
    assert Path.basename(broken) == "broken.md"
    assert message =~ "names nope"
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"))
    assert {:error, :not_found} = Agent.status(AgentID.parse!("#{org}/broken"))
  end

  test "a file whose agent cannot be keyed is reported, and the rest still run", %{
    dir: dir,
    org: org
  } do
    write(%{dir: dir, org: org}, "alpha", "")
    write(%{dir: dir, org: "#{org}/eu"}, "slashed", "")

    start_supervised!({Agents, dir: dir})

    assert [{_alpha, {:ok, _}}, {slashed, {:error, message}}] = Agents.files()
    assert Path.basename(slashed) == "slashed.md"
    assert message =~ "slashed.md: an agent's org is"
    assert message =~ "which is not a segment"
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"))
  end

  test "a file whose reading fails outright is reported, and the rest still run",
       %{org: org} = context do
    write(context, "alpha", "")
    write(context, "failing", "")

    stub(WardrikDaemon.AgentFile, :parse, fn path ->
      if Path.basename(path) == "failing.md",
        do: exit(:store_timeout),
        else: call_original(WardrikDaemon.AgentFile, :parse, [path])
    end)

    start_supervised!({Agents, dir: context.dir})

    assert [{_alpha, {:ok, _}}, {failing, {:error, message}}] = Agents.files()
    assert message == "#{failing}: (exit) :store_timeout"
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"))
  end

  test "a policy in policies/ governs the agents that name it", %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    write(context, "alpha", "policy: careful\n")

    start_supervised!({Agents, dir: context.dir})

    assert [{_policy, {:ok, %WardrikPolicy{name: "careful"} = careful}}, {_alpha, {:ok, spec}}] =
             Agents.files()

    assert spec.hooks == WardrikPolicy.hooks(careful)
    assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"))
  end

  test "notify started after it routes the agents its files route", %{org: org} = context do
    WardrikDaemon.Test.Settings.keep()
    targets = [audit: {WardrikNotify.Webhook, url: "https://hooks.test"}]
    Application.put_env(:wardrik_daemon, WardrikNotify, targets: targets)
    notify = [routes: {Agents, :routes, []}, targets: targets]

    write(context, "alpha", "notify: audit\n")
    start_supervised!({Agents, dir: context.dir})
    start_supervised!({WardrikNotify.Supervisor, notify})
    _files = Agents.files()

    alpha = AgentID.parse!("#{org}/alpha")
    assert %{^alpha => %WardrikNotify.Route{targets: [:audit]}} = Agents.routes()

    stop_supervised!(WardrikNotify.Supervisor)
    start_supervised!({WardrikNotify.Supervisor, notify})
    assert :sys.get_state(WardrikNotify.Dispatcher).routes == Agents.routes()
  end

  test "reads a definition sent to the HTTP API under the policies it read, and keeps it",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    start_supervised!({Agents, dir: context.dir})
    defined = AgentID.parse!("#{org}/defined")

    assert {:ok, spec} = Agents.put(defined, %{"policy" => "careful"}, grant(org))
    assert [%Wardrik.Hook{name: "careful", module: WardrikPolicy}] = spec.hooks
    assert Agents.get(defined) == {:ok, %{"policy" => "careful"}}

    assert {:error, message} = Agents.put(defined, %{"policy" => "lax"}, grant(org))
    assert message =~ "policy names lax"
    assert Agents.get(defined) == {:ok, %{"policy" => "careful"}}

    assert Agents.delete(defined) == :ok
    assert Agents.get(defined) == {:error, :not_found}
    assert Agents.delete(defined) == {:error, :not_found}
  end

  test "a definition shares only the trees the scope of the token that sent it covers",
       %{org: org} = context do
    start_supervised!({Agents, dir: context.dir})
    defined = AgentID.parse!("#{org}/@jon/defined")
    fields = %{"tools" => ["files"], "workspace" => %{"shared" => %{"team" => org}}}

    assert {:ok, _spec} = Agents.put(defined, fields, grant(org))

    assert {:error, message} =
             Agents.put(defined, fields, grant(Prefix.new!(org: org, user: "jon")))

    assert message ==
             "workspace shared team: #{org} belongs to #{org}/, which #{org}/@jon/ does not cover"
  end

  test "an agent the HTTP API defined is held to the ceiling of the token that sent it",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    start_supervised!({Agents, dir: context.dir})
    defined = AgentID.parse!("#{org}/defined")

    ceiling = [
      Wardrik.Hook.new("ceiling", WardrikPolicy, WardrikPolicy.decode!(%{"deny" => ["*"]}))
    ]

    {:ok, grant} = Wardrik.Grant.new(Prefix.new!(org: org), Wardrik.Grant.actions(), ceiling)

    {:ok, _spec} = Agents.put(defined, %{"policy" => "careful"}, grant)

    assert {:ok, spec} = Agents.spec(defined)
    assert [%{name: "ceiling"}, %{name: "careful"}] = spec.hooks
  end

  test "a conversation runs on the definition of its agent, in the agent's tree",
       %{org: org} = context do
    write(context, "alpha", "model: anthropic:claude-haiku-4-5\ntools: [files]\n")
    start_supervised!({Agents, dir: context.dir})
    thread = AgentID.parse!("#{org}/alpha/1696.1234")

    assert {:ok, spec} = Agents.spec(thread)
    assert spec.id == thread
    assert spec.config.model_spec == "anthropic:claude-haiku-4-5"
    assert [{WardrikWorkspace, workspace}] = spec.config.tools
    assert workspace.tree.tree == "agents/#{org}/alpha"
  end

  test "reload brings a conversation to its file, and leaves it where the file does not read",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    write(context, "alpha", "policy: careful\n")
    start_supervised!({Agents, dir: context.dir})
    thread = AgentID.parse!("#{org}/alpha/1696.1234")
    {:ok, options} = Agents.options(thread)
    {:ok, _pid} = Fleet.spawn(thread, options)

    write(context, "alpha", "policy: lax\n")
    Agents.reload()

    assert [_policy, {_alpha, {:error, message}}] = Agents.files()
    assert message =~ "names lax"
    assert Agents.problems() == []

    File.rm!(Path.join([context.dir, "policies", "careful.yaml"]))
    write(context, "alpha", "")
    Agents.reload()

    assert Agents.problems() == []
    assert {:ok, %{hooks: []}} = Agents.spec(thread)
  end

  test "reload brings the agents the HTTP API defined to what their definitions write now",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    start_supervised!({Agents, dir: context.dir})
    defined = AgentID.parse!("#{org}/defined")
    {:ok, spec} = Agents.put(defined, %{"policy" => "careful"}, grant(org))
    {:ok, _pid} = Fleet.put(spec)

    Agents.reload()
    assert Agents.problems() == []

    File.rm!(Path.join([context.dir, "policies", "careful.yaml"]))
    Agents.reload()

    assert Agents.problems() == [
             "#{defined} does not build from its definition: " <>
               "policy names careful, which is not a policy in policies/"
           ]

    :ok = Fleet.forget(defined)
    Agents.reload()

    assert Agents.problems() == []
    assert Agents.get(defined) == {:error, :not_found}
  end

  test "an agent starts with its file's options, or the defaults where no file declares it",
       %{org: org} = context do
    previous = Application.get_env(:wardrik_daemon, Agents)
    on_exit(fn -> Application.put_env(:wardrik_daemon, Agents, previous || []) end)

    Application.put_env(:wardrik_daemon, Agents,
      defaults: %{"model" => "anthropic:claude-sonnet-5"}
    )

    write(context, "alpha", "model: anthropic:claude-haiku-4-5\n")
    start_supervised!({Agents, dir: context.dir})

    assert Agents.dir() == context.dir
    assert {:ok, options} = Agents.options(AgentID.parse!("#{org}/alpha"))
    assert options[:config].model_spec == "anthropic:claude-haiku-4-5"
    assert {:ok, options} = Agents.options(AgentID.parse!("#{org}/@jon/assistant"))
    assert options[:config].model_spec == "anthropic:claude-sonnet-5"

    Application.put_env(:wardrik_daemon, Agents, defaults: %{"tools" => ["nothing"]})
    assert {:error, message} = Agents.options(AgentID.parse!("#{org}/assistant"))
    assert message =~ "tools names nothing"
  end

  test "leaves an agent a file declares to its file", %{org: org} = context do
    write(context, "alpha", "")
    start_supervised!({Agents, dir: context.dir})
    message = "#{org}/alpha is declared by agents/alpha.md; change the file"

    assert Agents.put(AgentID.parse!("#{org}/alpha"), %{}, grant(org)) ==
             {:error, :conflict, message}

    assert Agents.delete(AgentID.parse!("#{org}/alpha")) == {:error, :conflict, message}
    assert Agents.editable(AgentID.parse!("#{org}/alpha")) == {:error, :conflict, message}

    assert Agents.put_trigger(AgentID.parse!("#{org}/alpha"), "sweep", %{}) ==
             {:error, :conflict, message}

    assert Agents.delete_trigger(AgentID.parse!("#{org}/alpha"), "sweep") ==
             {:error, :conflict, message}
  end

  test "answers what it last read while it is busy reading again", %{org: org} = context do
    write(context, "alpha", "")
    write_policy(context, "careful", "deny: [run_lua]\n")
    start_supervised!({Agents, dir: context.dir})
    assert [_policy, _agent] = Agents.files()

    :ok = :sys.suspend(Agents)
    on_exit(fn -> if Process.whereis(Agents), do: :sys.resume(Agents) end)

    assert [{_careful, {:ok, %WardrikPolicy{}}}, {_alpha, {:ok, _spec}}] = Agents.files()
    assert Agents.dir() == context.dir
    assert Agents.problems() == []

    assert {:error, :conflict, _message} = Agents.editable(AgentID.parse!("#{org}/alpha"))
    assert Agents.editable(AgentID.parse!("#{org}/beta")) == :ok
    assert {:ok, _spec} = Agents.spec(AgentID.parse!("#{org}/alpha"))

    :ok = :sys.resume(Agents)
  end

  describe "an agent asleep" do
    test "is left asleep by a reload, and wakes with its file as it reads now",
         %{org: org} = context do
      write(context, "alpha", "idle_timeout: 1\nmodel: anthropic:claude-sonnet-5\n")
      start_supervised!({Agents, dir: context.dir})
      Agents.files()
      key = AgentID.parse!("#{org}/alpha")
      :ok = Wardrik.Event.Bus.subscribe(key)
      assert_receive %Wardrik.Event{payload: %Event.AgentStopped{reason: :idle}}, 3_000
      assert Wardrik.Test.Fleet.await_update(fn -> Fleet.whereis(key, wake: false) == nil end)

      write(context, "alpha", "idle_timeout: 1\nmodel: anthropic:claude-haiku-4-5\n")
      Agents.reload()

      assert Fleet.whereis(key, wake: false) == nil
      assert %{model: "anthropic:claude-haiku-4-5"} = Agent.status(key)
    end
  end

  describe "an agent the files no longer declare" do
    test "stops once its file is gone, and comes back as it was with the file",
         %{dir: dir, org: org} = context do
      write(context, "alpha", "")
      write(context, "beta", "triggers:\n  name: sweep\n  every: 1h\n  prompt: Look.\n")
      start_supervised!({Agents, dir: dir})
      Agents.files()
      %{generation: generation} = Agent.snapshot(AgentID.parse!("#{org}/beta"))

      File.rm!(Path.join([dir, "agents", "beta.md"]))
      Agents.reload()

      assert Fleet.whereis(AgentID.parse!("#{org}/beta"), wake: false) == nil
      assert WardrikTrigger.for_agent(AgentID.parse!("#{org}/beta")) == []
      assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"))

      write(context, "beta", "")
      Agents.reload()

      assert %{generation: ^generation} = Agent.snapshot(AgentID.parse!("#{org}/beta"))
    end

    test "stops when its file names another agent", %{org: org} = context do
      write(context, "alpha", "")
      start_supervised!({Agents, dir: context.dir})

      write(context, "alpha", "name: gamma\n")
      Agents.reload()

      assert Fleet.whereis(AgentID.parse!("#{org}/alpha"), wake: false) == nil
      assert %{} = Agent.status(AgentID.parse!("#{org}/gamma"))
    end

    test "runs on while another node's files declare it", %{dir: dir, org: org} = context do
      other = :"agents-test@elsewhere"
      write(context, "beta", "")
      start_supervised!({Agents, dir: dir, nodes: fn -> [other] end})
      Agents.files()

      {:ok, _vsn} = WardrikStore.put(:declared, "agents/#{other}", %{"#{org}/beta" => "beta.md"})
      on_exit(fn -> WardrikStore.delete(:declared, "agents/#{other}") end)

      File.rm!(Path.join([dir, "agents", "beta.md"]))
      Agents.reload()

      assert %{} = Agent.status(AgentID.parse!("#{org}/beta"))

      assert Agents.editable(AgentID.parse!("#{org}/beta")) ==
               {:error, :conflict,
                "#{org}/beta is declared by agents/beta.md on #{other}; change the file"}
    end

    test "is left as it was while its file does not read", %{org: org} = context do
      write(context, "alpha", "")
      start_supervised!({Agents, dir: context.dir})

      write(context, "alpha", "tools: [nope]\n")
      Agents.reload()
      assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"))

      write(context, "alpha", "")
      Agents.reload()
      assert %{} = Agent.status(AgentID.parse!("#{org}/alpha"))
    end

    test "leaves an agent the HTTP API defined alone", %{org: org} = context do
      write(context, "alpha", "")
      start_supervised!({Agents, dir: context.dir})

      {:ok, spec} =
        Agents.put(AgentID.parse!("#{org}/defined"), %{"instructions" => "You help."}, grant(org))

      {:ok, _pid} = Fleet.put(spec)

      File.rm!(Path.join([context.dir, "agents", "alpha.md"]))
      Agents.reload()

      assert Fleet.whereis(AgentID.parse!("#{org}/alpha"), wake: false) == nil
      assert %{} = Agent.status(AgentID.parse!("#{org}/defined"))
      assert :ok = Agents.editable(AgentID.parse!("#{org}/defined"))
    end
  end

  test "an agent naming a policy that does not read does not run", %{org: org} = context do
    write_policy(context, "careful", "deny: run_lua\n")
    write(context, "alpha", "policy: careful\n")

    start_supervised!({Agents, dir: context.dir})

    assert [{_policy, {:error, policy_error}}, {_alpha, {:error, agent_error}}] = Agents.files()
    assert policy_error =~ "careful.yaml: deny is a list"
    assert agent_error =~ "names careful"
    assert Fleet.whereis(AgentID.parse!("#{org}/alpha"), wake: false) == nil
  end

  test "runs the triggers a file declares, and stops those it no longer does",
       %{org: org} = context do
    write(context, "alpha", "triggers:\n  name: sweep\n  every: 1h\n  prompt: Look.\n")
    start_supervised!({Agents, dir: context.dir})
    assert [{_alpha, {:ok, _spec}}] = Agents.files()

    assert [%WardrikTrigger.Status{name: "sweep"}] =
             WardrikTrigger.for_agent(AgentID.parse!("#{org}/alpha"))

    assert WardrikDaemon.status() =~ ~r"#{org}/alpha .*next run in 5\dm"

    write(context, "alpha", "")
    Agents.reload()

    assert WardrikTrigger.for_agent(AgentID.parse!("#{org}/alpha")) == []
  end

  test "brings an agent the HTTP API defined to the triggers its definition lists",
       %{org: org} = context do
    start_supervised!({Agents, dir: context.dir})
    defined = AgentID.parse!("#{org}/defined")
    sweep = %{"name" => "sweep", "every" => "1h", "prompt" => "Look."}

    {:ok, _spec} = Agents.put(defined, %{"triggers" => [sweep]}, grant(org))
    assert [%{name: "sweep"}] = WardrikTrigger.for_agent(defined)

    {:ok, _spec} = Agents.put(defined, %{}, grant(org))
    assert WardrikTrigger.for_agent(defined) == []

    {:ok, _spec} = Agents.put(defined, %{"triggers" => [sweep]}, grant(org))
    :ok = Agents.delete(defined)
    assert WardrikTrigger.for_agent(defined) == []
  end

  test "changes one trigger in the definition the HTTP API sent", %{org: org} = context do
    start_supervised!({Agents, dir: context.dir})
    defined = AgentID.parse!("#{org}/defined")
    sweep = %{"name" => "sweep", "every" => "1h", "prompt" => "Look."}
    {:ok, _spec} = Agents.put(defined, %{"triggers" => [sweep]}, grant(org))

    assert {:ok, :created, digest} =
             Agents.put_trigger(defined, "digest", %{
               "every" => "0 17 * * *",
               "prompt" => "Sum up."
             })

    assert digest == %{
             "name" => "digest",
             "every" => "0 17 * * *",
             "prompt" => "Sum up.",
             "overlap" => "skip",
             "missed" => "run_once",
             "jitter" => 0
           }

    schema = WardrikProtocol.dir() |> Path.join("trigger.json") |> File.read!() |> JSON.decode!()
    assert {:ok, _} = JSV.validate(digest, JSV.build!(schema, resolver: WardrikProtocol.Resolver))

    assert {:ok, :changed, %{"every" => "2h"}} =
             Agents.put_trigger(defined, "sweep", %{"every" => "2h", "prompt" => "Look."})

    assert {:ok, %{"triggers" => [%{"name" => "sweep", "every" => "2h"}, %{"name" => "digest"}]}} =
             Agents.get(defined)

    assert [%{name: "digest"}, %{name: "sweep", every: {:interval, 7_200_000}}] =
             WardrikTrigger.for_agent(defined)

    assert {:error, ~s(trigger digest: every: "10s" is shorter than a minute)} =
             Agents.put_trigger(defined, "digest", %{"every" => "10s", "prompt" => "Sum up."})

    assert :ok = Agents.delete_trigger(defined, "digest")
    assert {:error, :not_found} = Agents.delete_trigger(defined, "digest")
    assert [%{name: "sweep"}] = WardrikTrigger.for_agent(defined)

    assert {:error, :not_found} =
             Agents.put_trigger(
               AgentID.parse!("#{org}/nobody"),
               "sweep",
               Map.delete(sweep, "name")
             )
  end

  test "reads a policy written as .yml, and reports a second file of the same name",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    File.write!(Path.join([context.dir, "policies", "careful.yml"]), "default: allow\n")
    File.write!(Path.join([context.dir, "policies", "strict.yml"]), "default: deny\n")
    write(context, "alpha", "policy: strict\n")

    start_supervised!({Agents, dir: context.dir})

    assert [
             {careful_yaml, {:ok, %WardrikPolicy{name: "careful"}}},
             {careful_yml, {:error, message}},
             {_strict, {:ok, %WardrikPolicy{name: "strict"}}},
             {_alpha, {:ok, _spec}}
           ] = Agents.files()

    assert Path.basename(careful_yaml) == "careful.yaml"
    assert message == "#{careful_yml}: policy careful is already careful.yaml"
    assert [_member] = Fleet.list(Prefix.parse!(org <> "/"))
  end

  test "offers in a channel the agents whose files name it, of the orgs it serves",
       %{org: org} = context do
    Application.put_env(:wardrik_daemon, WardrikChannel, orgs: [slack: [org], everyone: :all])
    on_exit(fn -> Application.delete_env(:wardrik_daemon, WardrikChannel) end)

    write(context, "books", "channels: [slack]\n")
    write(context, "triage", "channels: [slack, everyone]\n")
    write(context, "quiet", "")
    start_supervised!({Agents, dir: context.dir})
    # Answered once the files have been read.
    _files = Agents.files()

    assert Enum.map(Agents.offered("slack"), & &1.agent) ==
             [AgentID.parse!("#{org}/books"), AgentID.parse!("#{org}/triage")]

    everyone = Enum.map(Agents.offered("everyone"), & &1.agent)
    assert AgentID.parse!("#{org}/triage") in everyone
    refute AgentID.parse!("#{org}/books") in everyone

    Application.put_env(:wardrik_daemon, WardrikChannel, orgs: [slack: ["elsewhere"]])
    assert Agents.offered("slack") == []
    assert Agents.offered("nowhere") == []
  end

  test "creates an agent for a room from the defaults, where they name a policy and the channel lets it",
       %{org: org} = context do
    Application.put_env(:wardrik_daemon, WardrikChannel,
      orgs: [slack: [org], closed: [org]],
      creates: [slack: true, closed: false]
    )

    Application.put_env(:wardrik_daemon, Agents,
      defaults: %{"model" => "anthropic:claude-sonnet-5"}
    )

    previous = Application.get_env(:wardrik_daemon, Agents)

    on_exit(fn ->
      Application.delete_env(:wardrik_daemon, WardrikChannel)
      Application.put_env(:wardrik_daemon, Agents, previous || [])
    end)

    write_policy(context, "careful", "deny: [run_lua]\n")
    start_supervised!({Agents, dir: context.dir})
    _files = Agents.files()
    maria = Wardrik.Principal.new(:slack, "U1", name: "maria")

    refute Agents.creatable?("slack")

    assert {:error, "Agents are not created from here" <> _} =
             Agents.create("slack", "books", maria)

    Application.put_env(:wardrik_daemon, Agents,
      defaults: %{"model" => "anthropic:claude-sonnet-5", "policy" => "careful"}
    )

    assert Agents.creatable?("slack")
    refute Agents.creatable?("closed")

    assert {:ok, %WardrikChannel.Offer{agent: id, description: "Answers in #Books & Bills."}} =
             Agents.create("slack", "Books & Bills", maria)

    assert id == AgentID.parse!("#{org}/books-bills")
    assert Fleet.lookup(id)
    assert id in Enum.map(Agents.offered("slack"), & &1.agent)

    assert Wardrik.Test.Audit.about("agents/#{id}") ==
             [{"agent.defined", %{"type" => "slack", "id" => "U1", "name" => "maria"}}]

    assert {:error, message} = Agents.create("slack", "books-bills", maria)
    assert message =~ "#{org}/books-bills is there already"

    assert {:error, "Agents are not created from here" <> _} = Agents.create("closed", "x", maria)
    assert {:error, ~s("!!!" makes no agent's name.)} = Agents.create("slack", "!!!", maria)
  end

  test "starts the agent of a room's thread on its definition, and names the channel's approvers",
       %{org: org} = context do
    Application.put_env(:wardrik_daemon, WardrikChannel,
      orgs: [slack: [org]],
      approvers: [slack: ["@maria"]]
    )

    on_exit(fn -> Application.delete_env(:wardrik_daemon, WardrikChannel) end)

    write(context, "books", "channels: [slack]\ndescription: Keeps the books.\n")
    start_supervised!({Agents, dir: context.dir})
    _files = Agents.files()

    thread = AgentID.put_external_id(AgentID.parse!("#{org}/books"), "C1-1.1")
    assert {:ok, pid} = Agents.start("slack", thread)
    assert Fleet.whereis(thread) == pid
    assert Agents.start("slack", thread) == {:ok, pid}
    assert Agent.status(thread).model == Agent.status(AgentID.parse!("#{org}/books")).model

    assert Agents.approvers("slack") == ["@maria"]
    assert Agents.approvers("other") == []
  end

  test "no agents/ at all runs nothing", %{tmp_dir: dir} do
    start_supervised!({Agents, dir: Path.join(dir, "missing")})
    assert Agents.files() == []
  end
end
