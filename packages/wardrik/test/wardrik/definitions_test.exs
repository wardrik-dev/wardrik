defmodule Wardrik.DefinitionsTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Fleet
  alias Wardrik.Resource
  alias WardrikDefinition.Context

  defmodule Search do
    use Wardrik.Tool

    @impl Wardrik.Tool
    def tool,
      do:
        Wardrik.Tool.new!(
          name: "web_search",
          description: "Searches.",
          run: fn input, _context -> {:ok, input} end
        )
  end

  # A context whose files declare what a test gives.
  defmodule Files do
    defstruct [:context, files: []]
  end

  defimpl WardrikDefinition.Contexts, for: Files do
    def context(%{context: context}, _owner), do: context
    def reload(%{files: files}, _opts), do: files
  end

  # Holds each org's agents to the allowance it pays for, as a host that
  # bills its orgs would: a policy value of its own, by org.
  defmodule Allowances do
    defstruct [:base, :usd]
  end

  defimpl WardrikDefinition.Contexts, for: Allowances do
    def context(%{base: base, usd: usd}, owner) do
      org = to_string(Wardrik.Resource.org(owner))
      budget = %{"usd" => Map.fetch!(usd, org), "per" => "total", "on_exhausted" => "deny"}
      %{base | held: base.held ++ [WardrikPolicy.decode!(%{"budget" => budget}, "allowance")]}
    end

    def reload(_allowances, _opts), do: []
  end

  setup do
    org = "kept-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      own = Resource.parse!(org <> "/agent/*")

      for trigger <- WardrikTrigger.list(own),
          do: WardrikTrigger.delete(trigger.agent, trigger.name)

      Fleet.forget_under(own)
    end)

    careful = WardrikPolicy.decode!(%{"deny" => ["run_lua"]}, "careful")
    context = %Context{policies: %{"careful" => careful}}

    %{org: org, context: context, definitions: definitions(context)}
  end

  defp definitions(contexts), do: %Definitions{store: Wardrik.Test.store(), contexts: contexts}

  # The suite's host, holding the tool definitions name.
  defp host, do: Wardrik.Host.register(Wardrik.Test.host(), :tools, [{"web_search", Search}])

  defp token(pattern, policy) do
    %Wardrik.Token{
      principal: Wardrik.Principal.new("acme/@jon"),
      scope: [Wardrik.Role.bind([:owner], [pattern])],
      policy: policy
    }
  end

  # Reads `fields` as `id`'s definition, sent by a token over its org, keeps
  # it, and answers the spec it writes.
  defp put(definitions, id, fields, opts \\ []) do
    source = {:api, token(Resource.parse!(id.org <> "/agent/*"), opts[:policy] || :none)}

    with {:ok, definition} <-
           Definition.read(fields,
             id: id,
             source: opts[:source] || source,
             context: Definitions.context(definitions, id),
             held: opts[:held] || []
           ),
         :ok <- Definitions.put(definitions, definition),
         do: Definitions.spec(definitions, id, host: host())
  end

  test "keeps a definition, answers it, and forgets it", %{org: org, definitions: definitions} do
    id = AgentID.parse!("#{org}/defined")
    fields = %{"policy" => "careful", "tools" => ["web_search"]}

    assert {:ok, spec} = put(definitions, id, fields)
    assert [%Wardrik.Hook{name: "careful"}] = spec.hooks

    assert {:ok, %Definition{fields: ^fields, policy: "careful"}} =
             Definitions.get(definitions, id)

    assert [%Definition{id: ^id}] = Definitions.list(definitions, Resource.parse!(org <> "/*"))

    assert Definitions.delete(definitions, id) == :ok
    assert Definitions.get(definitions, id) == {:error, :not_found}
    assert Definitions.delete(definitions, id) == {:error, :not_found}
    assert Definitions.spec(definitions, id, host: host()) == {:error, :not_found}
  end

  test "an agent is held to the hooks it was defined under, then its token's policy, by name",
       %{org: org, definitions: definitions} = test do
    id = AgentID.parse!("#{org}/defined")
    held = [Wardrik.Hook.new("held", WardrikPolicy, WardrikPolicy.decode!(%{"deny" => ["*"]}))]

    assert {:ok, spec} =
             put(definitions, id, %{"policy" => "careful"}, policy: "careful", held: held)

    assert [%{name: "held"}, %{name: "policy/careful"}, %{name: "careful"}] = spec.hooks
    assert {:ok, ^spec} = Wardrik.Specs.current(definitions, id, host: host())

    lax = %{test.context | policies: %{"lax" => WardrikPolicy.decode!(%{}, "lax")}}
    without = definitions(lax)
    assert {:error, message} = put(without, id, %{"policy" => "lax"}, policy: "careful")
    assert message =~ "the token that defined it names the policy careful, which is not a policy"

    assert {:error, "the token that defined it names the policy careful" <> _} =
             Definitions.spec(without, id, host: host())

    assert Wardrik.Specs.current(without, id, host: host()) == :none
  end

  test "reads each definition under the context its agent's owner is given",
       %{org: org} = test do
    other = "#{org}-other"

    definitions =
      definitions(%Wardrik.ByOrg{contexts: %{org => test.context, other => %Context{}}})

    assert {:ok, _spec} =
             put(definitions, AgentID.parse!("#{org}/defined"), %{"policy" => "careful"})

    assert {:error, message} =
             put(definitions, AgentID.parse!("#{other}/defined"), %{"policy" => "careful"})

    assert message =~ "policy names careful"
  end

  test "holds each org's agents to the policy its contexts give the org, which they spend together",
       %{org: org, context: context} do
    other = org <> "-other"
    allowances = %Allowances{base: context, usd: %{org => 5, other => 1}}
    definitions = definitions(allowances)
    one = AgentID.parse!("#{org}/one")
    jon = AgentID.parse!("#{org}/@jon/two")
    theirs = AgentID.parse!("#{other}/one")

    ceilings =
      for id <- [one, jon, theirs] do
        assert {:ok, spec} = put(definitions, id, %{"policy" => "careful"})
        assert ["held/allowance", "held/allowance/budget", "careful"] = names(spec)
        allowance(spec)
      end

    {ours, others} = {Resource.parse!(org), Resource.parse!(other)}
    assert [pooled, pooled, %WardrikPolicy.Ceiling{org: ^others, budget: %{usd: 1.0}}] = ceilings

    assert %WardrikPolicy.Ceiling{
             org: ^ours,
             budget: %{usd: 5.0, per: :total, meter: "held/allowance/budget"}
           } = pooled

    raised = definitions(%{allowances | usd: %{org => 8, other => 1}})
    assert {:ok, spec} = Definitions.spec(raised, one, host: host())
    assert %{budget: %{usd: 8.0}} = allowance(spec)
  end

  defp names(spec), do: Enum.map(spec.hooks, & &1.name)
  defp allowance(spec), do: Enum.find(spec.hooks, &(&1.name == "held/allowance/budget")).value

  test "keeps one an agent file declares from all but its file",
       %{org: org, definitions: definitions} do
    id = AgentID.parse!("#{org}/declared")
    file = {:file, "/etc/wardrik/agents/declared.md"}
    assert {:ok, _spec} = put(definitions, id, %{}, source: file)

    refusal =
      "#{id} is declared by agents/declared.md; change or remove that file, then reload it"

    assert {:error, :conflict, ^refusal} = Definitions.editable(definitions, id)
    assert {:error, :conflict, ^refusal} = put(definitions, id, %{"model" => "test:model"})
    assert {:error, :conflict, ^refusal} = Definitions.put_trigger(definitions, id, "t", %{})
    assert {:error, :conflict, ^refusal} = Definitions.delete_trigger(definitions, id, "t")
    assert {:ok, _spec} = put(definitions, id, %{"model" => "test:model"}, source: file)
    assert Definitions.editable(definitions, AgentID.parse!("#{org}/nobody")) == :ok
  end

  test "keeps where an agent's notices go with its definition, until it is forgotten",
       %{org: org, definitions: definitions} do
    id = AgentID.parse!("#{org}/defined")

    route = fn ->
      with {:ok, definition} <- Definitions.get(definitions, id), do: definition.notify
    end

    {:ok, _spec} = put(definitions, id, %{"notify" => "audit"})
    assert %WardrikDefinition.Route{targets: ["audit"]} = route.()

    {:ok, _spec} = put(definitions, id, %{})
    assert route.() == nil

    {:ok, _spec} = put(definitions, id, %{"notify" => %{"to" => "audit", "on" => ["finished"]}})
    assert %WardrikDefinition.Route{on: [:finished]} = route.()

    :ok = Definitions.delete(definitions, id)
    assert route.() == {:error, :not_found}
  end

  test "brings an agent to the triggers its definition lists",
       %{org: org, definitions: definitions} do
    id = AgentID.parse!("#{org}/defined")
    sweep = %{"name" => "sweep", "every" => "1h", "prompt" => "Look."}

    {:ok, _spec} = put(definitions, id, %{"triggers" => [sweep]})
    assert [%{name: "sweep"}] = WardrikTrigger.for_agent(id)

    {:ok, _spec} = put(definitions, id, %{})
    assert WardrikTrigger.for_agent(id) == []

    {:ok, _spec} = put(definitions, id, %{"triggers" => [sweep]})
    :ok = Definitions.delete(definitions, id)
    assert WardrikTrigger.for_agent(id) == []
  end

  test "changes one trigger in the definition kept", %{org: org, definitions: definitions} do
    id = AgentID.parse!("#{org}/defined")
    sweep = %{"name" => "sweep", "every" => "1h", "prompt" => "Look."}
    {:ok, _spec} = put(definitions, id, %{"triggers" => [sweep]})
    daily = %{"every" => "0 17 * * *", "prompt" => "Sum up."}

    assert {:ok, :created, digest} = Definitions.put_trigger(definitions, id, "digest", daily)

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
             Definitions.put_trigger(definitions, id, "sweep", %{
               "every" => "2h",
               "prompt" => "Look."
             })

    assert {:ok,
            %Definition{
              fields: %{
                "triggers" => [%{"name" => "sweep", "every" => "2h"}, %{"name" => "digest"}]
              }
            }} = Definitions.get(definitions, id)

    assert [%{name: "digest"}, %{name: "sweep", schedule: "every 2h"}] =
             WardrikTrigger.for_agent(id)

    assert {:error, ~s(trigger digest: every: "10s" is shorter than a minute)} =
             Definitions.put_trigger(definitions, id, "digest", %{daily | "every" => "10s"})

    assert {:ok, %{"name" => "digest", "prompt" => "Sum up."}} =
             Definitions.delete_trigger(definitions, id, "digest")

    assert {:error, :not_found} = Definitions.delete_trigger(definitions, id, "digest")
    assert [%{name: "sweep"}] = WardrikTrigger.for_agent(id)

    assert {:error, :not_found} =
             Definitions.put_trigger(
               definitions,
               AgentID.parse!("#{org}/nobody"),
               "sweep",
               Map.delete(sweep, "name")
             )
  end

  test "reload builds every agent awake again, and keeps the definitions of agents not stored",
       %{org: org, definitions: definitions} = test do
    id = AgentID.parse!("#{org}/defined")
    {:ok, spec} = put(definitions, id, %{"policy" => "careful"})
    {:ok, _pid} = Fleet.put(spec)

    assert %{reloaded: reloaded, failed: failed} =
             Definitions.reload(definitions, host: host())

    assert id in reloaded
    assert of(failed, org) == []

    without = definitions(%{test.context | policies: %{}})
    assert %{failed: failed} = Definitions.reload(without, host: host())

    assert List.last(failed) =~ "#{id} does not build from its definition: policy names careful"

    :ok = Fleet.forget(id)
    assert %{failed: failed} = Definitions.reload(definitions, host: host())
    assert of(failed, org) == []
    assert {:ok, _definition} = Definitions.get(definitions, id)
  end

  test "reload keeps what files declare now, retires what none does, and reads the rest again",
       %{org: org, context: context} do
    [api, kept, unread, retired, added] =
      for name <- ~w(api kept unread retired added), do: AgentID.parse!("#{org}/#{name}")

    definitions = definitions(%Files{context: context})
    {:ok, _spec} = put(definitions, api, %{})

    for id <- [kept, unread, retired],
        do: {:ok, _spec} = put(definitions, id, %{}, source: file(id))

    {:ok, _pid} = Fleet.put(Wardrik.Agent.Spec.new(id: retired))

    later = %{context | defaults: %{"idle_timeout" => 60}}

    files = [
      {"agents/kept.md", read(kept, %{"description" => "Kept."}, later)},
      {"agents/unread.md", {:error, "agents/unread.md: tools is a list"}},
      {"agents/added.md", read(added, %{}, later)}
    ]

    definitions = definitions(%Files{context: later, files: files})

    assert %{reloaded: reloaded, failed: ["agents/unread.md: tools is a list" | failed]} =
             Definitions.reload(definitions, host: host())

    assert for(id <- reloaded, id.org == org, do: id) == [added, api, kept]
    assert of(failed, org) == []

    assert {:ok, %{idle_timeout: 60_000, source: {:api, _token}}} =
             Definitions.get(definitions, api)

    assert {:ok, %{description: "Kept."}} = Definitions.get(definitions, kept)
    assert {:ok, %{source: {:file, "agents/unread.md"}}} = Definitions.get(definitions, unread)
    assert {:ok, _added} = Definitions.get(definitions, added)
    assert Definitions.get(definitions, retired) == {:error, :not_found}
    assert Fleet.held_pid(retired, wake: false) == nil
    assert Fleet.stored?(retired)
  end

  # Every definition in the suite's store is read again; these are the
  # messages of the test's own org's.
  defp of(messages, org), do: Enum.filter(messages, &String.contains?(&1, org))

  defp file(id), do: {:file, "agents/#{id.name}.md"}

  defp read(id, fields, context),
    do: Definition.read(fields, id: id, source: file(id), context: context)

  test "keeps each definition under its agent's resource name, and names those a pattern covers",
       %{org: org, definitions: definitions} do
    one = AgentID.parse!("#{org}/one")
    other = AgentID.parse!("#{org}/@jon/other")
    {:ok, _spec} = put(definitions, one, %{})
    {:ok, _spec} = put(definitions, other, %{})

    assert Wardrik.Specs.defined(definitions, Resource.parse!(org <> "/*")) == [other, one]
    assert Wardrik.Specs.defined(definitions, Resource.parse!(org <> "/agent/*")) == [one]
    assert Wardrik.Specs.defined(definitions, AgentID.resource(other)) == [other]

    assert Enum.sort(WardrikStore.keys(definitions.store, :definitions, org <> "/")) ==
             ["#{org}/@jon/agent/other", "#{org}/agent/one"]
  end
end
