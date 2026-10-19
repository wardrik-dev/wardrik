defmodule WardrikDefinitionTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Resource
  alias WardrikDefinition.Context

  defmodule Clock do
    use Wardrik.Tool

    @impl Wardrik.Tool
    def tool,
      do:
        Wardrik.Tool.new!(
          name: "clock",
          description: "The time.",
          run: fn _, _context -> {:ok, "noon"} end
        )
  end

  defmodule Source do
    use Wardrik.Tool

    @impl Wardrik.Tool
    def tools(_argument), do: []
  end

  # The servers owners added, by owner.
  defmodule Added do
    defstruct by: %{}
  end

  defimpl Wardrik.Servers, for: Added do
    def list(%Added{by: by}, owner) do
      for name <- Map.get(by, to_string(owner), []),
          do: %Wardrik.Servers.Server{
            name: name,
            url: "https://#{name}.example/mcp",
            auth: "none"
          }
    end

    def add(_added, _owner, _opts), do: :unsupported
    def remove(_added, _owner, _opts), do: :unsupported
  end

  setup do
    {:ok, careful} = WardrikPolicy.decode(%{"ask" => ["books/*"]})

    context = %Context{
      org: "acme",
      tools: [Clock],
      servers: [books: [serves: [Wardrik.Resource.parse!("acme/*")]], wiki: []],
      mcp: Source,
      channels: [chat: :all, ops: ["globex"]],
      targets: [pager: {Source, orgs: :all}],
      policies: %{"careful" => careful},
      defaults: %{"idle_timeout" => 60},
      names: %{host: "Mode", config: "Mode", policies: "the org's policies"}
    }

    %{context: context, id: AgentID.parse!("acme/triage")}
  end

  defp spec(fields, context, id, source \\ :defaults),
    do: WardrikDefinition.spec(fields, id, id, context, source)

  test "takes the keys its schema lists, in order" do
    schema =
      WardrikProtocol.dir()
      |> Path.join("agent_definition.json")
      |> File.read!()
      |> JSON.decode!()

    assert Enum.sort(WardrikDefinition.keys()) == Enum.sort(Map.keys(schema["properties"]))
    assert ["description", "instructions" | _rest] = WardrikDefinition.keys()

    assert Enum.sort(WardrikDefinition.file_keys()) ==
             Enum.sort((WardrikDefinition.keys() -- ["instructions"]) ++ ~w(name org user))
  end

  test "reads a definition into the spec it writes, with what the host gives every agent",
       %{context: context, id: id} do
    fields = %{
      "instructions" => "Watch the queue.",
      "model" => "test:model",
      "tools" => ["clock", "books/*"],
      "policy" => "careful",
      "notify" => "pager"
    }

    assert {:ok, spec} = spec(fields, context, id, {:file, "triage.md"})
    assert spec.config.system == "Watch the queue."
    assert spec.config.tools == [Clock, {Source, Resource.parse!("deployment/server/books")}]
    assert [_hook | _hooks] = spec.hooks
    assert spec.idle_timeout == :timer.seconds(60)
    assert {:ok, %{targets: [:pager]}} = WardrikDefinition.route(fields, id, context)

    assert {:ok, %{config: %{tool_prices: %{"clock" => 0.01}}}} =
             spec(
               %{},
               %{
                 context
                 | runtimes: [%Wardrik.LLM.Runtime{config: [tool_prices: %{"clock" => 0.01}]}]
               },
               id
             )

    assert {:ok, %{idle_timeout: :infinity}} =
             spec(%{"idle_timeout" => "infinity"}, context, id)
  end

  test "says why a definition does not read, in the host's words", %{context: context, id: id} do
    assert {:error, "tools names nope/*, but Mode configures no server nope; it has " <> _} =
             spec(%{"tools" => ["nope/*"]}, context, id)

    assert {:error, "tools names books/*, but Mode's books serves acme/*, and not globex/triage"} =
             spec(%{"tools" => ["books/*"]}, context, AgentID.parse!("globex/triage"))

    assert {:error, "tools names web_search, which is not a tool Mode ships"} =
             spec(%{"tools" => ["web_search"]}, context, id)

    assert {:error, "policy names loose, which is not a policy in the org's policies"} =
             spec(%{"policy" => "loose"}, context, id)

    assert {:error, "channels names ops, which Mode keeps for another org"} =
             spec(%{"channels" => ["ops"]}, context, id)
  end

  test "names a server or a source only where the host has them", %{context: context, id: id} do
    assert {:error, "tools names workers/*, but Mode configures no server workers" <> _} =
             spec(%{"tools" => ["workers/*"]}, context, id)

    assert {:error, "tools names books/*, but Mode configures no server books" <> _} =
             spec(%{"tools" => ["books/*"]}, %{context | mcp: nil}, id)

    assert {:ok, spec} =
             spec(%{"tools" => ["workers/*"]}, %{context | sources: [workers: Source]}, id)

    assert spec.config.tools == [{Source, id}]
  end

  test "names a server its owner added, and one its owner has yet to add",
       %{context: context, id: id} do
    context = %{context | added: %Added{by: %{"acme" => ["crm"]}}}
    owner = Resource.owner(Wardrik.AgentID.resource(id))

    assert {:ok, spec} = spec(%{"tools" => ["crm/*", "books/*", "later/*"]}, context, id)

    assert spec.config.tools == [
             {Source, Resource.new(owner, server: "crm")},
             {Source, Resource.parse!("deployment/server/books")},
             {Source, Resource.new(owner, server: "later")}
           ]

    fields = %{"tools" => ["clock", "crm/*", "books/*", "later/*"]}
    assert WardrikDefinition.missing(fields, id, context) == ["later/*"]

    jon = AgentID.parse!("acme/@jon/triage")
    assert WardrikDefinition.missing(%{"tools" => ["crm/*"]}, jon, context) == ["crm/*"]
  end

  test "names no server it has not configured where owners add none",
       %{context: context, id: id} do
    assert WardrikDefinition.missing(%{"tools" => ["nope/*"]}, id, context) == []

    assert {:error, "tools names nope/*, but Mode configures no server nope" <> _} =
             spec(%{"tools" => ["nope/*"]}, context, id)
  end

  test "a definition a token sent names no module, and holds after no label",
       %{context: context, id: id} do
    assert {:error, "policy names Elixir.Kernel, which is not a policy in the org's policies"} =
             spec(%{"policy" => "Elixir.Kernel"}, context, id)

    assert {:error,
            "policy cannot allow_after in a definition; name a policy in the org's policies that does"} =
             WardrikDefinition.accept(id, %{"policy" => %{"allow_after" => %{}}}, context)

    assert {:error, "acme/triage/t1 is a conversation of acme/triage; define acme/triage"} =
             WardrikDefinition.accept(AgentID.parse!("acme/triage/t1"), %{}, context)
  end

  test "an org's policies come ahead of the agent's own policy", %{context: context, id: id} do
    {:ok, base} = WardrikPolicy.decode(%{"deny" => ["run_lua"]})
    policies = Map.put(context.policies, "base", base)
    context = %{context | policies: policies, ceilings: %{"*" => "base", "acme" => "careful"}}

    assert {:ok, spec} = spec(%{"policy" => %{"ask" => ["web_search"]}}, context, id)
    assert ["orgs/*/base", "orgs/acme/careful", "policy"] = Enum.map(spec.hooks, & &1.name)

    context = %{context | ceilings: %{"acme" => "missing"}}

    assert {:error,
            "Mode holds acme's agents to the policy missing, which is not a policy in " <>
              "the org's policies"} = spec(%{}, context, id)
  end

  test "an agent is in one of the orgs the context declares", %{context: context, id: id} do
    context = %{context | orgs: ["globex"]}

    assert {:error, "acme is not an org Mode declares: globex"} =
             WardrikDefinition.accept(id, %{}, context)

    assert {:error, "acme is not an org Mode declares: globex"} =
             WardrikDefinition.parse("---\norg: acme\n---\n", "triage", context)

    assert {:ok, _id, _fields} =
             WardrikDefinition.parse("---\norg: globex\n---\n", "triage", context)
  end

  test "reads an agent file into the agent it declares and its definition", %{context: context} do
    text = "---\nname: triage\nuser: jon\nmodel: test:model\n---\nWatch the queue.\n"

    assert {:ok, id, %{"model" => "test:model", "instructions" => "Watch the queue."}} =
             WardrikDefinition.parse(text, "file-name", context)

    assert to_string(id) == "acme/@jon/triage"

    assert {:ok, %AgentID{name: "file-name", org: "acme"}, %{}} =
             WardrikDefinition.parse("", "file-name", context)

    assert {:error, "notify? is not a setting; expected one of name, org, user" <> _} =
             WardrikDefinition.parse("---\nnotify?: x\n---\n", "file-name", context)
  end

  test "checks a host's defaults" do
    assert :ok =
             WardrikDefinition.check_defaults(%{"model" => "test:model", "idle_timeout" => 60})

    assert {:error, "idle_timeout", "is a whole number of seconds, or infinity"} =
             WardrikDefinition.check_defaults(%{"idle_timeout" => 0})

    assert :ok = WardrikDefinition.check_defaults(%{"retries" => %{"attempts" => 3}})

    assert {:error, "retries", "is a set of attempts, max_wait and on_exhausted"} =
             WardrikDefinition.check_defaults(%{"retries" => "often"})

    assert {:error, "retries.on_exhausted", "is ask or fail"} =
             WardrikDefinition.check_defaults(%{"retries" => %{"on_exhausted" => "never"}})

    assert {:error, "name", "is not a setting; expected one of model, tools" <> _} =
             WardrikDefinition.check_defaults(%{"name" => "x"})
  end

  test "changes and removes one trigger" do
    fields = %{"triggers" => %{"every" => "1h", "prompt" => "Look."}}

    assert {:ok, fields, :created, %WardrikTrigger{name: "sweep"}} =
             WardrikDefinition.put_trigger(fields, "sweep",
               trigger: %{"every" => "2h", "prompt" => "Go."},
               context: %WardrikDefinition.Context{}
             )

    assert [%{name: "trigger-1"}, %{name: "sweep"}] =
             WardrikDefinition.triggers(fields, %WardrikDefinition.Context{})

    assert {:ok, %{"triggers" => [%{"name" => "sweep"}]}} =
             WardrikDefinition.delete_trigger(fields, "trigger-1")

    assert {:error, :not_found} = WardrikDefinition.delete_trigger(fields, "nope")
  end
end
