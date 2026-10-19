defmodule Wardrik.RunningTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID

  setup_all do
    # Each org's agents read their definitions against a context of the org's own.
    context = %Wardrik.ByOrg{contexts: %{"acme" => Wardrik.context(org: "acme")}}

    wardrik =
      Wardrik.new(
        store: Wardrik.Test.store(),
        issuer: %Wardrik.OrgIssuer{org: "acme"},
        context: context,
        tools: [Wardrik.RunningTest.Search]
      )

    %{wardrik: wardrik}
  end

  defmodule Search do
    @moduledoc false
    use Wardrik.Tool

    @impl true
    def tool do
      Wardrik.Tool.new!(
        name: "search",
        description: "Searches.",
        schema: [],
        run: {__MODULE__, :run, []}
      )
    end

    def run(_input, _context), do: {:ok, "nothing"}
  end

  defp maria, do: Wardrik.Principal.new(:user, "maria")

  test "a user defines an agent their token reaches, read against its org's context, and kept",
       %{wardrik: wardrik} do
    agent = AgentID.new!("support", org: "acme")

    definition = %{
      "model" => "anthropic:claude-sonnet-5",
      "instructions" => "Answer briefly.",
      "tools" => ["search"]
    }

    session = Wardrik.as(wardrik, maria())

    assert {:ok, _snapshot} = Wardrik.agent_define(session, agent, definition)

    assert {:ok,
            %{definition: %Wardrik.Definition{fields: %{"instructions" => "Answer briefly."}}}} =
             Wardrik.agent_definition_read(session, agent)
  end

  test "a user reaches nothing their token does not", %{wardrik: wardrik} do
    agent = AgentID.new!("support", org: "globex")

    assert {:error, %Wardrik.Error{type: :not_found}} =
             wardrik |> Wardrik.as(maria()) |> Wardrik.agent_read(agent)
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
