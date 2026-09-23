defmodule TarsDaemon.AgentsTest do
  use ExUnit.Case, async: false

  alias Tars.Agent
  alias Tars.Fleet
  alias TarsDaemon.Agents

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    org = "agents-#{System.unique_integer([:positive])}"
    on_exit(fn -> Fleet.forget_under(org <> "/") end)
    %{dir: dir, org: org}
  end

  defp write(%{dir: dir, org: org}, name, front) do
    File.write!(Path.join(dir, "#{name}.md"), "---\norg: #{org}\n#{front}---\nYou help.\n")
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

  test "no agents/ at all runs nothing", %{tmp_dir: dir} do
    start_supervised!({Agents, dir: Path.join(dir, "missing")})
    assert Agents.files() == []
  end
end
