defmodule Wardrik.RunningTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Operations.Define
  alias Wardrik.Operations.ReadDefinition

  setup_all do
    dir = Path.join(System.tmp_dir!(), "wardrik-#{System.unique_integer([:positive])}")

    # Each org's agents read their definitions against a context of the org's own.
    context = %Wardrik.ByOrg{
      contexts: %{"acme" => Wardrik.context(tools: [Wardrik.RunningTest.Search])}
    }

    wardrik =
      Wardrik.new(
        store: Wardrik.store(data_dir: dir),
        grants: %Wardrik.OrgGrants{org: "acme"},
        context: context
      )

    start_supervised!({Wardrik, wardrik})
    :ok = DurableServer.Supervisor.wait_until_ready(Wardrik.Fleet, timeout: 10_000)

    on_exit(fn -> File.rm_rf(dir) end)
    %{wardrik: wardrik}
  end

  defmodule Search do
    @moduledoc false
    @behaviour Wardrik.Tool

    @impl true
    def tool do
      ReqLLM.Tool.new!(
        name: "search",
        description: "Searches.",
        parameter_schema: [],
        callback: {__MODULE__, :run}
      )
    end

    def run(_input), do: {:ok, "nothing"}
  end

  defp maria, do: Wardrik.Principal.new(:user, "maria")

  test "a user defines an agent their grant reaches, read against its org's context, and kept",
       %{wardrik: wardrik} do
    agent = AgentID.new!("support", org: "acme")

    definition = %{
      "model" => "anthropic:claude-sonnet-5",
      "instructions" => "Answer briefly.",
      "tools" => ["search"]
    }

    {:ok, caller} = Wardrik.caller(wardrik, principal: maria(), subject: agent)

    assert {:created, _snapshot} =
             Wardrik.Command.run(%Define{agent: agent, definition: definition}, caller)

    assert {:ok, %Wardrik.Definition.Read{fields: %{"instructions" => "Answer briefly."}}} =
             Wardrik.Query.run(%ReadDefinition{agent: agent}, caller)
  end

  test "a user reaches nothing their grant does not", %{wardrik: wardrik} do
    agent = AgentID.new!("support", org: "globex")

    assert {:error, %Wardrik.Error{type: :not_found}} =
             Wardrik.caller(wardrik, principal: maria(), subject: agent)
  end

  test "an agent spawned in the fleet runs, as a host that spawns its own does" do
    agent = AgentID.new!("scratch-#{System.unique_integer([:positive])}", org: "acme")
    config = Wardrik.LLM.Config.new(system: "You answer briefly.")

    assert {:ok, pid} = Wardrik.Fleet.spawn(agent, config: config)
    assert Process.alive?(pid)
  end

  test "the meters and the triggers run on the store" do
    assert is_pid(Process.whereis(WardrikPolicy.Supervisor))
    assert is_pid(Process.whereis(WardrikTrigger.supervisor()))
  end
end
