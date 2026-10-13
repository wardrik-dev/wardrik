defmodule Wardrik.CatalogTest do
  # The host's definitions module is one for the node, which these tests set.
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Call
  alias Wardrik.Catalog
  alias Wardrik.Catalog.Tools
  alias Wardrik.Definition
  alias Wardrik.Test.Tools.Rules

  # Keeps nothing: tells the test what it was asked, and refuses an agent
  # whose name holds "filed", as a host refuses one a file declares. Calls run
  # in the tool runner, so it finds the test by the name it registers.
  defmodule Kept do
    @moduledoc false
    @behaviour Wardrik.Definition

    @impl true
    def put(_id, _definition, _grant), do: {:error, "not here"}

    @impl true
    def get(_id), do: {:ok, %{"description" => "Watches.", "triggers" => []}}

    @impl true
    def put_trigger(id, name, fields) do
      tell({:put_trigger, id, name, fields})

      if String.contains?(id.name, "filed"),
        do: {:error, :conflict, "#{id} belongs to a file."},
        else: {:ok, :created, Map.put(fields, "name", name)}
    end

    @impl true
    def delete_trigger(id, name) do
      tell({:delete_trigger, id, name})
      :ok
    end

    defp tell(message), do: send(:persistent_term.get(__MODULE__), message)
  end

  setup do
    :persistent_term.put(Kept, self())
    :ignore = Definition.configure(Kept)

    on_exit(fn ->
      Definition.configure(nil)
      :persistent_term.erase(Kept)
    end)

    %{agent: AgentID.parse!("acme/watch-#{System.unique_integer([:positive])}")}
  end

  @trigger %{
    "every" => "30m",
    "feed" => "https://rivalco.example/changelog.rss",
    "prompt" => "Look."
  }

  defp scope(agent, opts \\ []),
    do: Wardrik.Test.scope([tools: [{Tools, agent}], id: agent] ++ opts)

  test "offers the catalog's agent operations as tools, each described as it is" do
    agent = AgentID.parse!("acme/watch")

    assert [read, set, remove] = Tools.tools(agent)

    assert {read.name, set.name, remove.name} ==
             {"agent_definition_read", "agent_trigger_set", "agent_trigger_remove"}

    assert set.description == Wardrik.Operations.SetTrigger.summary()
    assert set.parameter_schema == Wardrik.Operations.SetTrigger.input()

    assert Catalog.agent_commands() == [
             Wardrik.Operations.SetTrigger,
             Wardrik.Operations.RemoveTrigger
           ]

    assert Tools.annotations(agent, "agent_trigger_set") == %{gated: true}
    assert Tools.annotations(agent, "agent_definition_read") == %{}
  end

  test "a change waits on a person, then runs as the agent itself", %{agent: agent} do
    scope = scope(agent)

    waiting =
      Wardrik.Test.call(scope, "agent_trigger_set", %{"name" => "rivals", "trigger" => @trigger})

    assert %Call{state: :waiting} = waiting
    refute_received {:put_trigger, _id, _name, _fields}

    assert %Call{state: :done, result: {:ok, %{"trigger" => %{"name" => "rivals"}}}} =
             Wardrik.Test.resume(scope, waiting)

    assert_received {:put_trigger, ^agent, "rivals", @trigger}

    assert Wardrik.Test.Audit.about("agents/#{agent}") |> List.last() ==
             {"trigger.set", %{"type" => "agent", "id" => to_string(agent)}}
  end

  test "a conversation's call changes its agent", %{agent: agent} do
    conversation = AgentID.put_external_id(agent, "thread-1")
    hooks = [Wardrik.Hook.new("rules", Rules, allow: ["agent_trigger_remove"])]

    assert %Call{state: :done, result: {:ok, "done"}} =
             conversation
             |> scope(hooks: hooks)
             |> Wardrik.Test.call("agent_trigger_remove", %{"name" => "rivals"})

    assert_received {:delete_trigger, ^agent, "rivals"}
  end

  test "a read runs without waiting on anyone", %{agent: agent} do
    assert %Call{state: :done, result: {:ok, %{"description" => "Watches."}}} =
             agent |> scope() |> Wardrik.Test.call("agent_definition_read", %{})
  end

  test "answers what does not read, or what another surface declares, as it would there",
       %{agent: agent} do
    hooks = [Wardrik.Hook.new("rules", Rules, allow: ["agent_trigger_set"])]

    assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "invalid_request"}}}} =
             agent
             |> scope(hooks: hooks)
             |> Wardrik.Test.call("agent_trigger_set", %{"name" => "x"})

    filed = AgentID.parse!("acme/filed")

    assert %Call{state: :done, result: {:error, %{"error" => %{"type" => "conflict"}}}} =
             filed
             |> scope(hooks: hooks)
             |> Wardrik.Test.call("agent_trigger_set", %{
               "name" => "rivals",
               "trigger" => @trigger
             })
  end
end
