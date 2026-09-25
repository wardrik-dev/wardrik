defmodule TarsDaemon.AgentsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Tars.Agent
  alias Tars.Fleet
  alias TarsDaemon.Agents

  @moduletag :tmp_dir

  setup :set_mimic_global

  setup %{tmp_dir: dir} do
    org = "agents-#{System.unique_integer([:positive])}"
    on_exit(fn -> Fleet.forget_under(org <> "/") end)
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
    assert Agent.status("#{org}/_/beta").model == "anthropic:claude-sonnet-5"

    assert Enum.sort(Enum.map(Fleet.list(org <> "/"), & &1.key)) == [
             "#{org}/_/alpha",
             "#{org}/_/beta"
           ]
  end

  test "reload/0 gives a running agent what its file says now", %{org: org} = context do
    write(context, "alpha", "")
    start_supervised!({Agents, dir: context.dir})
    {:ok, pid} = Fleet.spawn("#{org}/_/alpha")

    write(context, "alpha", "model: anthropic:claude-sonnet-5\n")
    Agents.reload()

    assert {:ok, ^pid} = Fleet.spawn("#{org}/_/alpha")
    assert Agent.status("#{org}/_/alpha").model == "anthropic:claude-sonnet-5"
  end

  test "a file that does not read is reported, and the rest still run", %{org: org} = context do
    write(context, "alpha", "")
    write(context, "broken", "tools: [nope]\n")

    start_supervised!({Agents, dir: context.dir})

    assert [{_alpha, {:ok, _}}, {broken, {:error, message}}] = Agents.files()
    assert Path.basename(broken) == "broken.md"
    assert message =~ "names nope"
    assert %{} = Agent.status("#{org}/_/alpha")
    assert {:error, :not_found} = Agent.status("#{org}/_/broken")
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
    assert message =~ "slashed.md: a fleet key segment may not contain \"/\""
    assert %{} = Agent.status("#{org}/_/alpha")
  end

  test "a file whose reading fails outright is reported, and the rest still run",
       %{org: org} = context do
    write(context, "alpha", "")
    write(context, "failing", "")

    stub(TarsDaemon.AgentFile, :load, fn path, policies ->
      if Path.basename(path) == "failing.md",
        do: exit(:store_timeout),
        else: call_original(TarsDaemon.AgentFile, :load, [path, policies])
    end)

    start_supervised!({Agents, dir: context.dir})

    assert [{_alpha, {:ok, _}}, {failing, {:error, message}}] = Agents.files()
    assert message == "#{failing}: (exit) :store_timeout"
    assert %{} = Agent.status("#{org}/_/alpha")
  end

  test "a policy in policies/ governs the agents that name it", %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    write(context, "alpha", "policy: careful\n")

    start_supervised!({Agents, dir: context.dir})

    assert [{_policy, {:ok, %TarsPolicy{name: "careful"} = careful}}, {_alpha, {:ok, spec}}] =
             Agents.files()

    assert spec.hooks == TarsPolicy.hooks(careful)
    assert %{} = Agent.status("#{org}/_/alpha")
  end

  test "reads a definition sent to the HTTP API under the policies it read",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    start_supervised!({Agents, dir: context.dir})

    assert {:ok, spec} = Agents.put("#{org}/_/defined", %{"policy" => "careful"})
    assert [%Tars.Hook{name: "careful", module: TarsPolicy}] = spec.hooks

    assert {:error, message} = Agents.put("#{org}/_/defined", %{"policy" => "lax"})
    assert message =~ "policy names lax"

    assert Agents.delete("#{org}/_/defined") == {:error, :not_found}
  end

  test "leaves an agent a file declares to its file", %{org: org} = context do
    write(context, "alpha", "")
    start_supervised!({Agents, dir: context.dir})
    message = "#{org}/_/alpha is declared by agents/alpha.md; change the file"

    assert Agents.put("#{org}/_/alpha", %{}) == {:error, :conflict, message}
    assert Agents.delete("#{org}/_/alpha") == {:error, :conflict, message}
  end

  test "an agent naming a policy that does not read does not run", %{org: org} = context do
    write_policy(context, "careful", "deny: run_lua\n")
    write(context, "alpha", "policy: careful\n")

    start_supervised!({Agents, dir: context.dir})

    assert [{_policy, {:error, policy_error}}, {_alpha, {:error, agent_error}}] = Agents.files()
    assert policy_error =~ "careful.yaml: deny is a list"
    assert agent_error =~ "names careful"
    assert {:error, :not_found} = Agent.status("#{org}/_/alpha")
  end

  test "runs the schedules a file declares, and stops those it no longer does",
       %{org: org} = context do
    write(context, "alpha", "schedule:\n  name: sweep\n  every: 1h\n  prompt: Look.\n")
    start_supervised!({Agents, dir: context.dir})
    assert [{_alpha, {:ok, _spec}}] = Agents.files()

    assert [%Tars.Schedule.Status{name: "sweep"}] = Tars.Schedule.for_agent("#{org}/_/alpha")
    assert TarsDaemon.status() =~ ~r"#{org}/_/alpha .*next run in 5\dm"

    write(context, "alpha", "")
    Agents.reload()

    assert Tars.Schedule.for_agent("#{org}/_/alpha") == []
  end

  test "reads a policy written as .yml, and reports a second file of the same name",
       %{org: org} = context do
    write_policy(context, "careful", "deny: [run_lua]\n")
    File.write!(Path.join([context.dir, "policies", "careful.yml"]), "default: allow\n")
    File.write!(Path.join([context.dir, "policies", "strict.yml"]), "default: deny\n")
    write(context, "alpha", "policy: strict\n")

    start_supervised!({Agents, dir: context.dir})

    assert [
             {careful_yaml, {:ok, %TarsPolicy{name: "careful"}}},
             {careful_yml, {:error, message}},
             {_strict, {:ok, %TarsPolicy{name: "strict"}}},
             {_alpha, {:ok, _spec}}
           ] = Agents.files()

    assert Path.basename(careful_yaml) == "careful.yaml"
    assert message == "#{careful_yml}: policy careful is already careful.yaml"
    assert [_member] = Fleet.list(org <> "/")
  end

  test "no agents/ at all runs nothing", %{tmp_dir: dir} do
    start_supervised!({Agents, dir: Path.join(dir, "missing")})
    assert Agents.files() == []
  end
end
