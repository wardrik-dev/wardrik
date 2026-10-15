defmodule WardrikDefinition.KeptTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Definition
  alias Wardrik.Fleet
  alias WardrikDefinition.Context
  alias WardrikDefinition.Kept

  defmodule Search do
    @behaviour Wardrik.Tool

    @impl Wardrik.Tool
    def tool,
      do: ReqLLM.Tool.new!(name: "web_search", description: "Searches.", callback: &{:ok, &1})
  end

  # A context for each org, as a host holding orgs to policies of their own does.
  defmodule ByOrg do
    defstruct [:contexts]
  end

  defimpl WardrikDefinition.Contexts, for: ByOrg do
    def context(%ByOrg{contexts: contexts}, owner),
      do: Map.get(contexts, owner.org, %WardrikDefinition.Context{})
  end

  setup do
    org = "kept-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      prefix = Prefix.parse!(org <> "/")

      for trigger <- WardrikTrigger.list(prefix),
          do: WardrikTrigger.delete(trigger.agent, trigger.name)

      Fleet.forget_under(prefix)
    end)

    careful = WardrikPolicy.decode!(%{"deny" => ["run_lua"]}, "careful")

    context = %Context{
      tools: [Search],
      targets: [audit: {Search, []}],
      policies: %{"careful" => careful}
    }

    %{org: org, context: context, kept: kept(context)}
  end

  defp kept(contexts), do: %Kept{store: Wardrik.Test.store(), contexts: contexts}

  defp grant(%Prefix{} = scope, ceiling \\ []) do
    {:ok, grant} = Wardrik.Grant.new(scope, Wardrik.Grant.actions(), ceiling)
    grant
  end

  defp put(kept, id, fields),
    do: Definition.put(kept, id, definition: fields, grant: grant(Prefix.new!(org: id.org)))

  test "keeps a definition, answers it as sent, and forgets it", %{org: org, kept: kept} do
    id = AgentID.parse!("#{org}/defined")

    assert {:ok, spec} = put(kept, id, %{"policy" => "careful", "tools" => ["web_search"]})
    assert [%Wardrik.Hook{name: "careful"}] = spec.hooks
    assert Definition.get(kept, id) == {:ok, %{"policy" => "careful", "tools" => ["web_search"]}}

    assert {:error, message} = put(kept, id, %{"policy" => "lax"})
    assert message =~ "policy names lax"
    assert {:ok, %{"policy" => "careful"}} = Definition.get(kept, id)

    assert Definition.delete(kept, id) == :ok
    assert Definition.get(kept, id) == {:error, :not_found}
    assert Definition.delete(kept, id) == {:error, :not_found}
  end

  test "an agent is held to the ceiling of the grant that defined it", %{org: org, kept: kept} do
    id = AgentID.parse!("#{org}/defined")

    ceiling = [
      Wardrik.Hook.new("ceiling", WardrikPolicy, WardrikPolicy.decode!(%{"deny" => ["*"]}))
    ]

    {:ok, _spec} =
      Definition.put(kept, id,
        definition: %{"policy" => "careful"},
        grant: grant(Prefix.new!(org: org), ceiling)
      )

    assert {:ok, spec} = Definition.current(kept, id)
    assert [%{name: "ceiling"}, %{name: "careful"}] = spec.hooks
  end

  test "a conversation runs on the definition of its agent", %{org: org, kept: kept} do
    {:ok, _spec} = put(kept, AgentID.parse!("#{org}/defined"), %{"tools" => ["web_search"]})
    thread = AgentID.parse!("#{org}/defined/1696.1234")

    assert {:ok, spec} = Definition.current(kept, thread)
    assert spec.id == thread
    assert spec.config.tools == [Search]
    assert Definition.current(kept, AgentID.parse!("#{org}/nobody")) == :none
  end

  test "reads each definition under the context its agent's owner is given", %{org: org} = test do
    other = "#{org}-other"
    kept = kept(%ByOrg{contexts: %{org => test.context, other => %Context{}}})

    assert {:ok, _spec} = put(kept, AgentID.parse!("#{org}/defined"), %{"policy" => "careful"})

    assert {:error, message} =
             put(kept, AgentID.parse!("#{other}/defined"), %{"policy" => "careful"})

    assert message =~ "policy names careful"
  end

  test "creates no agent, and lets every agent be changed", %{org: org, kept: kept} do
    id = AgentID.parse!("#{org}/nobody")

    assert Definition.create(kept, id) == :unsupported
    assert Definition.editable(kept, id) == :ok
    assert Definition.reloading(kept) == [node()]
  end

  test "routes the agents whose definitions name a target, until they are forgotten",
       %{org: org, kept: kept} do
    id = AgentID.parse!("#{org}/defined")

    {:ok, _spec} = put(kept, id, %{"notify" => "audit"})
    assert %{^id => %WardrikNotify.Route{targets: [:audit]}} = Kept.routes(kept)

    {:ok, _spec} = put(kept, id, %{})
    refute is_map_key(Kept.routes(kept), id)

    {:ok, _spec} = put(kept, id, %{"notify" => %{"to" => "audit", "on" => ["finished"]}})
    assert %{^id => %WardrikNotify.Route{on: [:finished]}} = Kept.routes(kept)

    :ok = Definition.delete(kept, id)
    refute is_map_key(Kept.routes(kept), id)
  end

  test "brings an agent to the triggers its definition lists", %{org: org, kept: kept} do
    id = AgentID.parse!("#{org}/defined")
    sweep = %{"name" => "sweep", "every" => "1h", "prompt" => "Look."}

    {:ok, _spec} = put(kept, id, %{"triggers" => [sweep]})
    assert [%{name: "sweep"}] = WardrikTrigger.for_agent(id)

    {:ok, _spec} = put(kept, id, %{})
    assert WardrikTrigger.for_agent(id) == []

    {:ok, _spec} = put(kept, id, %{"triggers" => [sweep]})
    :ok = Definition.delete(kept, id)
    assert WardrikTrigger.for_agent(id) == []
  end

  test "changes one trigger in the definition kept", %{org: org, kept: kept} do
    id = AgentID.parse!("#{org}/defined")
    sweep = %{"name" => "sweep", "every" => "1h", "prompt" => "Look."}
    {:ok, _spec} = put(kept, id, %{"triggers" => [sweep]})

    assert {:ok, :created, digest} =
             Definition.put_trigger(kept, id, "digest",
               fields: %{"every" => "0 17 * * *", "prompt" => "Sum up."}
             )

    assert digest == %{
             "name" => "digest",
             "every" => "0 17 * * *",
             "prompt" => "Sum up.",
             "overlap" => "skip",
             "missed" => "run_once",
             "jitter" => 0
           }

    assert {:ok, :changed, %{"every" => "2h"}} =
             Definition.put_trigger(kept, id, "sweep",
               fields: %{"every" => "2h", "prompt" => "Look."}
             )

    assert {:ok, %{"triggers" => [%{"name" => "sweep", "every" => "2h"}, %{"name" => "digest"}]}} =
             Definition.get(kept, id)

    assert [%{name: "digest"}, %{name: "sweep", schedule: "every 2h"}] =
             WardrikTrigger.for_agent(id)

    assert {:error, ~s(trigger digest: every: "10s" is shorter than a minute)} =
             Definition.put_trigger(kept, id, "digest",
               fields: %{"every" => "10s", "prompt" => "Sum up."}
             )

    assert :ok = Definition.delete_trigger(kept, id, "digest")
    assert {:error, :not_found} = Definition.delete_trigger(kept, id, "digest")
    assert [%{name: "sweep"}] = WardrikTrigger.for_agent(id)

    assert {:error, :not_found} =
             Definition.put_trigger(kept, AgentID.parse!("#{org}/nobody"), "sweep",
               fields: Map.delete(sweep, "name")
             )
  end

  test "a definition shares only the trees the scope of the grant that sent it covers",
       %{org: org, kept: kept} do
    id = AgentID.parse!("#{org}/defined")
    fields = %{"tools" => ["files"], "workspace" => %{"shared" => %{"team" => org}}}

    assert {:ok, _spec} =
             Definition.put(kept, id, definition: fields, grant: grant(Prefix.new!(org: org)))

    assert {:error, message} =
             Definition.put(kept, id, definition: fields, grant: grant(Prefix.of(id)))

    assert message ==
             "workspace shared team: #{org} belongs to #{org}/, which #{id} does not cover"
  end

  test "reload builds every agent awake again, and forgets the definitions of agents gone",
       %{org: org, kept: kept} = test do
    id = AgentID.parse!("#{org}/defined")
    {:ok, spec} = put(kept, id, %{"policy" => "careful"})
    {:ok, _pid} = Fleet.put(spec)

    assert Definition.reload(kept) == :ok

    without = kept(%{test.context | policies: %{}})

    assert capture_log(fn -> assert Definition.reload(without) == :ok end) =~
             "#{id} does not build from its definition: policy names careful"

    :ok = Fleet.forget(id)
    assert Definition.reload(kept) == :ok
    assert Definition.get(kept, id) == {:error, :not_found}
  end
end
