defmodule Tars.Agent.SupervisorTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Tars.Agent
  alias Tars.LLM.Config

  defp runner(test_pid) do
    fn scope, _context ->
      send(test_pid, {:turn, scope.source.agent_id})
      {:ok, [Context.assistant("ok")]}
    end
  end

  defp unique_name, do: :"agent_#{System.unique_integer([:positive])}"

  defp stop(pid), do: DynamicSupervisor.terminate_child(Tars.Agent.Supervisor, pid)

  test "is a singleton started by the application" do
    assert is_pid(Process.whereis(Tars.Agent.Supervisor))
    assert {:error, {:already_started, _pid}} = Tars.Agent.Supervisor.start_link()
  end

  test "starts a named agent that runs turns with the given config" do
    name = unique_name()
    tool = ReqLLM.Tool.new!(name: "echo", description: "e", callback: fn i -> {:ok, i} end)
    config = Config.new(tools: [tool])

    assert {:ok, pid} = Tars.Agent.Supervisor.start(name, config: config, runner: runner(self()))

    on_exit(fn ->
      if Process.alive?(pid), do: stop(pid)
    end)

    # The registered name doubles as the event id.
    Agent.ask(name, "hello")
    assert_receive {:turn, ^name}

    assert Process.whereis(name) == pid
  end

  test "starts with a default config when none is given" do
    name = unique_name()

    assert {:ok, pid} = Tars.Agent.Supervisor.start(name)
    on_exit(fn -> if Process.alive?(pid), do: stop(pid) end)

    assert Context.to_list(Agent.get_context(name)) == []
  end

  test "each agent keeps its own context" do
    one = unique_name()
    two = unique_name()

    {:ok, pid_one} =
      Tars.Agent.Supervisor.start(one, config: Config.new(), runner: runner(self()))

    {:ok, pid_two} =
      Tars.Agent.Supervisor.start(two, config: Config.new(), runner: runner(self()))

    on_exit(fn ->
      for pid <- [pid_one, pid_two], Process.alive?(pid), do: stop(pid)
    end)

    Agent.ask(one, "only for one")
    assert_receive {:turn, ^one}

    assert Context.to_list(Agent.get_context(two)) == []
  end
end
