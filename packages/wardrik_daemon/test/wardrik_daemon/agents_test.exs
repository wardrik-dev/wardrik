defmodule WardrikDaemon.AgentsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Wardrik.Agent
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Fleet
  alias WardrikDaemon.Agents

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup %{tmp_dir: dir} do
    org = "agents-#{System.unique_integer([:positive])}"
    on_exit(fn -> Fleet.forget_under(Prefix.parse!(org <> "/")) end)
    %{dir: dir, org: org}
  end

  defp write(%{dir: dir, org: org}, name, front) do
    File.mkdir_p!(Path.join(dir, "agents"))

    File.write!(
      Path.join([dir, "agents", "#{name}.md"]),
      "---\norg: #{org}\n#{front}---\nYou help.\n"
    )
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

    stub(WardrikDaemon.AgentFile, :load, fn path, policies ->
      if Path.basename(path) == "failing.md",
        do: exit(:store_timeout),
        else: call_original(WardrikDaemon.AgentFile, :load, [path, policies])
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

  test "reads a definition sent to the HTTP API under the policies it read",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    start_supervised!({Agents, dir: context.dir})

    assert {:ok, spec} =
             Agents.put(AgentID.parse!("#{org}/defined"), %{"policy" => "careful"})

    assert [%Wardrik.Hook{name: "careful", module: WardrikPolicy}] = spec.hooks

    assert {:error, message} =
             Agents.put(AgentID.parse!("#{org}/defined"), %{"policy" => "lax"})

    assert message =~ "policy names lax"

    assert Agents.delete(AgentID.parse!("#{org}/defined")) == {:error, :not_found}
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

    assert Agents.put(AgentID.parse!("#{org}/alpha"), %{}) == {:error, :conflict, message}
    assert Agents.delete(AgentID.parse!("#{org}/alpha")) == {:error, :conflict, message}
    assert Agents.editable(AgentID.parse!("#{org}/alpha")) == {:error, :conflict, message}
  end

  describe "an agent the files no longer declare" do
    test "stops once its file is gone, and comes back as it was with the file",
         %{dir: dir, org: org} = context do
      write(context, "alpha", "")
      write(context, "beta", "schedule:\n  name: sweep\n  every: 1h\n  prompt: Look.\n")
      start_supervised!({Agents, dir: dir})
      Agents.files()
      %{generation: generation} = Agent.snapshot(AgentID.parse!("#{org}/beta"))

      File.rm!(Path.join([dir, "agents", "beta.md"]))
      Agents.reload()

      assert {:error, :not_found} = Agent.status(AgentID.parse!("#{org}/beta"))
      assert Wardrik.Schedule.for_agent(AgentID.parse!("#{org}/beta")) == []
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

      assert {:error, :not_found} = Agent.status(AgentID.parse!("#{org}/alpha"))
      assert %{} = Agent.status(AgentID.parse!("#{org}/gamma"))
    end

    test "runs on while another node's files declare it", %{dir: dir, org: org} = context do
      other = :"agents-test@elsewhere"
      write(context, "beta", "")
      start_supervised!({Agents, dir: dir, nodes: fn -> [other] end})
      Agents.files()

      {:ok, _vsn} = Wardrik.Store.put(:declared, "agents/#{other}", %{"#{org}/beta" => "beta.md"})
      on_exit(fn -> Wardrik.Store.delete(:declared, "agents/#{other}") end)

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
        Agents.put(AgentID.parse!("#{org}/defined"), %{"instructions" => "You help."})

      {:ok, _pid} = Fleet.put(spec)

      File.rm!(Path.join([context.dir, "agents", "alpha.md"]))
      Agents.reload()

      assert {:error, :not_found} = Agent.status(AgentID.parse!("#{org}/alpha"))
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
    assert {:error, :not_found} = Agent.status(AgentID.parse!("#{org}/alpha"))
  end

  test "runs the schedules a file declares, and stops those it no longer does",
       %{org: org} = context do
    write(context, "alpha", "schedule:\n  name: sweep\n  every: 1h\n  prompt: Look.\n")
    start_supervised!({Agents, dir: context.dir})
    assert [{_alpha, {:ok, _spec}}] = Agents.files()

    assert [%Wardrik.Schedule.Status{name: "sweep"}] =
             Wardrik.Schedule.for_agent(AgentID.parse!("#{org}/alpha"))

    assert WardrikDaemon.status() =~ ~r"#{org}/alpha .*next run in 5\dm"

    write(context, "alpha", "")
    Agents.reload()

    assert Wardrik.Schedule.for_agent(AgentID.parse!("#{org}/alpha")) == []
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

  test "no agents/ at all runs nothing", %{tmp_dir: dir} do
    start_supervised!({Agents, dir: Path.join(dir, "missing")})
    assert Agents.files() == []
  end
end
