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
      do:
        Wardrik.Tool.new!(
          name: "web_search",
          description: "Searches.",
          run: fn input, _context -> {:ok, input} end
        )
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

  defp token(prefix, policy \\ :none) do
    %Wardrik.Token{
      principal: Wardrik.Principal.new(:user, "jon"),
      scope: [Wardrik.Role.bind([:owner], prefix)],
      policy: policy
    }
  end

  defp put(kept, id, fields),
    do:
      Definition.put(kept, id,
        definition: fields,
        token: token(Prefix.new!(org: id.org)),
        held: []
      )

  test "keeps a definition, answers it as sent, and forgets it", %{org: org, kept: kept} do
    id = AgentID.parse!("#{org}/defined")

    assert {:ok, spec} = put(kept, id, %{"policy" => "careful", "tools" => ["web_search"]})
    assert [%Wardrik.Hook{name: "careful"}] = spec.hooks

    assert Definition.get(kept, id) ==
             {:ok,
              %Definition.Read{
                fields: %{"policy" => "careful", "tools" => ["web_search"]},
                missing: []
              }}

    assert {:error, message} = put(kept, id, %{"policy" => "lax"})
    assert message =~ "policy names lax"
    assert {:ok, %Definition.Read{fields: %{"policy" => "careful"}}} = Definition.get(kept, id)

    assert Definition.delete(kept, id) == :ok
    assert Definition.get(kept, id) == {:error, :not_found}
    assert Definition.delete(kept, id) == {:error, :not_found}
  end

  test "an agent is held to the hooks it was defined under, then its token's policy, by name",
       %{org: org, kept: kept} = test do
    id = AgentID.parse!("#{org}/defined")
    held = [Wardrik.Hook.new("held", WardrikPolicy, WardrikPolicy.decode!(%{"deny" => ["*"]}))]

    assert {:ok, spec} =
             Definition.put(kept, id,
               definition: %{"policy" => "careful"},
               token: token(Prefix.new!(org: org), "careful"),
               held: held
             )

    assert [%{name: "policy/careful"}, %{name: "careful"}] = spec.hooks
    assert {:ok, spec} = Definition.current(kept, id)
    assert [%{name: "held"}, %{name: "policy/careful"}, %{name: "careful"}] = spec.hooks

    without = kept(%{test.context | policies: %{"lax" => WardrikPolicy.decode!(%{}, "lax")}})

    assert {:error, message} =
             Definition.put(without, id,
               definition: %{"policy" => "lax"},
               token: token(Prefix.new!(org: org), "careful"),
               held: []
             )

    assert message =~ "the token that defined it names the policy careful, which is not a policy"
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
             "timezone" => "Etc/UTC",
             "prompt" => "Sum up.",
             "overlap" => "skip",
             "missed" => "run_once",
             "jitter" => 0
           }

    assert {:ok, :changed, %{"every" => "2h"}} =
             Definition.put_trigger(kept, id, "sweep",
               fields: %{"every" => "2h", "prompt" => "Look."}
             )

    assert {:ok,
            %Definition.Read{
              fields: %{
                "triggers" => [%{"name" => "sweep", "every" => "2h"}, %{"name" => "digest"}]
              }
            }} = Definition.get(kept, id)

    assert [%{name: "digest"}, %{name: "sweep", schedule: "every 2h"}] =
             WardrikTrigger.for_agent(id)

    assert {:error, ~s(trigger digest: every: "10s" is shorter than a minute)} =
             Definition.put_trigger(kept, id, "digest",
               fields: %{"every" => "10s", "prompt" => "Sum up."}
             )

    assert {:ok, %{"name" => "digest", "prompt" => "Sum up."}} =
             Definition.delete_trigger(kept, id, "digest")

    assert {:error, :not_found} = Definition.delete_trigger(kept, id, "digest")
    assert [%{name: "sweep"}] = WardrikTrigger.for_agent(id)

    assert {:error, :not_found} =
             Definition.put_trigger(kept, AgentID.parse!("#{org}/nobody"), "sweep",
               fields: Map.delete(sweep, "name")
             )
  end

  test "a definition shares only the trees the token that sent it reaches",
       %{org: org, kept: kept} do
    id = AgentID.parse!("#{org}/defined")
    fields = %{"tools" => ["files"], "workspace" => %{"shared" => %{"team" => org}}}

    assert {:ok, _spec} =
             Definition.put(kept, id,
               definition: fields,
               token: token(Prefix.new!(org: org)),
               held: []
             )

    assert {:error, message} =
             Definition.put(kept, id, definition: fields, token: token(Prefix.of(id)), held: [])

    assert message ==
             "workspace shared team: #{org} belongs to #{org}/, which the token does not reach"
  end

  test "reload builds every agent awake again, and keeps the definitions of agents not stored",
       %{org: org, kept: kept} = test do
    id = AgentID.parse!("#{org}/defined")
    {:ok, spec} = put(kept, id, %{"policy" => "careful"})
    {:ok, _pid} = Fleet.put(spec)

    assert Definition.reload(kept, host: Wardrik.Test.host()) == :ok

    without = kept(%{test.context | policies: %{}})

    assert capture_log(fn ->
             assert Definition.reload(without, host: Wardrik.Test.host()) == :ok
           end) =~
             "#{id} does not build from its definition: policy names careful"

    :ok = Fleet.forget(id)
    assert Definition.reload(kept, host: Wardrik.Test.host()) == :ok
    assert {:ok, _definition} = Definition.get(kept, id)
  end

  test "names the agents it keeps a definition for under a prefix", %{org: org, kept: kept} do
    one = AgentID.parse!("#{org}/one")
    other = AgentID.parse!("#{org}/@jon/other")
    {:ok, _spec} = put(kept, one, %{})
    {:ok, _spec} = put(kept, other, %{})

    assert Enum.sort_by(Definition.defined(kept, Prefix.parse!(org <> "/*")), &to_string/1) ==
             [other, one]

    assert Definition.defined(kept, Prefix.of(other)) == [other]
  end
end
