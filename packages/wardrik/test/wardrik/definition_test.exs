defmodule Wardrik.DefinitionTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Definition
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
      servers: [books: [serves: [Wardrik.Resource.parse!("acme/*")]], wiki: []],
      mcp: Source,
      policies: %{"careful" => careful},
      defaults: %{"idle_timeout" => 60},
      names: %{host: "Mode", config: "Mode", policies: "the org's policies"}
    }

    %{context: context, id: AgentID.parse!("acme/triage")}
  end

  defp read(fields, context, id, source \\ :defaults),
    do: Definition.read(fields, id: id, source: source, context: context)

  defp host(opts \\ []),
    do: Wardrik.Host.register(Wardrik.Host.new(opts), :tools, [{"clock", Clock}])

  # The spec `fields` write for `id` under `context`, sent by no token, on
  # host/1 unless `:host` names another.
  defp spec(fields, context, id, opts \\ []) do
    with {:ok, definition} <- read(fields, context, id),
         do: built(definition, id, context, opts)
  end

  defp built(definition, id, context, opts \\ []),
    do:
      Definition.spec(definition, id,
        context: context,
        host: Keyword.get_lazy(opts, :host, &host/0)
      )

  test "takes the keys its schema lists, in order" do
    schema =
      WardrikProtocol.dir()
      |> Path.join("agent_definition.json")
      |> File.read!()
      |> JSON.decode!()

    assert Enum.sort(Definition.keys()) == Enum.sort(Map.keys(schema["properties"]))
    assert ["display_name", "description", "instructions" | _rest] = Definition.keys()

    assert Enum.sort(Definition.file_keys()) ==
             Enum.sort((Definition.keys() -- ["instructions"]) ++ ~w(name org user))
  end

  test "reads a definition into the spec it writes, with what the host gives every agent",
       %{context: context, id: id} do
    fields = %{
      "instructions" => "Watch the queue.",
      "model" => "test:model",
      "tools" => ["clock", "books/*"],
      "policy" => "careful",
      "notify" => "pager",
      "channels" => ["chat"]
    }

    assert {:ok, definition} = read(fields, context, id, {:file, "agents/triage.md"})
    assert definition.display_name == "triage"
    assert definition.tools == ["clock", "books/*"]
    assert definition.policy == "careful"
    assert definition.channels == ["chat"]
    assert %WardrikNotify.Route{targets: ["pager"]} = definition.notify
    assert definition.fields == fields

    assert {:ok, spec} = built(definition, id, context)
    assert spec.display_name == "triage"
    assert spec.config.system == "Watch the queue."
    assert spec.config.tools == [Clock, {Source, Resource.parse!("deployment/server/books")}]
    assert [_hook | _hooks] = spec.hooks
    assert spec.idle_timeout == :timer.seconds(60)

    assert {:ok, %{display_name: "Triage desk"}} =
             spec(%{"display_name" => "Triage desk"}, context, id)

    priced = [%Wardrik.LLM.Runtime{config: [tool_prices: %{"clock" => 0.01}]}]

    assert {:ok, %{config: %{tool_prices: %{"clock" => 0.01}}}} =
             spec(%{}, context, id, host: host(runtimes: priced))

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

    assert {:error, "channels is a list of the channels it is offered in"} =
             spec(%{"channels" => "chat"}, context, id)

    assert {:error, "notify names 1, which is not a target"} =
             spec(%{"notify" => [1]}, context, id)
  end

  test "applies the host's defaults once, as it reads", %{context: context, id: id} do
    assert {:ok, definition} = read(%{}, context, id)
    assert definition.idle_timeout == :timer.seconds(60)

    later = %{context | defaults: %{"idle_timeout" => 5}}
    assert {:ok, %{idle_timeout: 60_000}} = built(definition, id, later)
    assert {:ok, %{idle_timeout: 5_000}} = read(definition.fields, later, id)
  end

  test "keeps a policy it names by its name, found as its agent starts, and one in place as it reads",
       %{context: context, id: id} do
    assert {:ok, named} = read(%{"policy" => "careful"}, context, id)
    assert named.policy == "careful"

    assert {:error, "policy names careful, which is not a policy in the org's policies"} =
             built(named, id, %{context | policies: %{}})

    assert {:ok, inline} = read(%{"policy" => %{"deny" => ["clock"]}}, context, id)
    assert %WardrikPolicy{} = inline.policy

    assert {:ok, %{hooks: [%Wardrik.Hook{}]}} =
             built(inline, id, %{context | policies: %{}})
  end

  test "names a server or a source only where the host has them", %{context: context, id: id} do
    assert {:error, "tools names workers/*, but Mode configures no server workers" <> _} =
             spec(%{"tools" => ["workers/*"]}, context, id)

    assert {:error, "tools names books/*, but Mode configures no server books" <> _} =
             spec(%{"tools" => ["books/*"]}, %{context | mcp: nil}, id)

    workers = Wardrik.Host.register(host(), :sources, [{"workers", Source}])
    assert {:ok, spec} = spec(%{"tools" => ["workers/*"]}, context, id, host: workers)

    assert spec.config.tools == [{Source, id}]
  end

  test "names a server its owner added, and one its owner has yet to add",
       %{context: context, id: id} do
    host = host(servers: %Added{by: %{"acme" => ["crm"]}})
    owner = Resource.owner(Wardrik.AgentID.resource(id))

    assert {:ok, spec} =
             spec(%{"tools" => ["crm/*", "books/*", "later/*"]}, context, id, host: host)

    assert spec.config.tools == [
             {Source, Resource.new(owner, server: "crm")},
             {Source, Resource.parse!("deployment/server/books")},
             {Source, Resource.new(owner, server: "later")}
           ]

    {:ok, definition} = read(%{"tools" => ["clock", "crm/*", "books/*", "later/*"]}, context, id)
    assert Definition.missing(definition, context: context, host: host) == ["later/*"]

    jon = AgentID.parse!("acme/@jon/triage")
    {:ok, definition} = read(%{"tools" => ["crm/*"]}, context, jon)
    assert Definition.missing(definition, context: context, host: host) == ["crm/*"]
  end

  test "names no server it has not configured where owners add none",
       %{context: context, id: id} do
    assert {:error, "tools names nope/*, but Mode configures no server nope" <> _} =
             spec(%{"tools" => ["nope/*"]}, context, id)

    nope = %Definition{read!(context, id) | tools: ["nope/*"]}
    assert Definition.missing(nope, context: context, host: host()) == []
  end

  test "a definition a token sent names no module, and holds after no label",
       %{context: context, id: id} do
    assert {:error, "policy names Elixir.Kernel, which is not a policy in the org's policies"} =
             spec(%{"policy" => "Elixir.Kernel"}, context, id)

    assert {:error,
            "policy cannot allow_after in a definition; name a policy in the org's policies that does"} =
             read(%{"policy" => %{"allow_after" => %{}}}, context, id)

    assert {:error, "acme/triage/t1 is a conversation of acme/triage; define acme/triage"} =
             read(%{}, context, AgentID.parse!("acme/triage/t1"))
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

    assert {:error, "acme is not an org Mode declares: globex"} = read(%{}, context, id)

    assert {:error, "acme is not an org Mode declares: globex"} =
             Definition.parse("---\norg: acme\n---\n", "triage", context)

    assert {:ok, _id, _fields} =
             Definition.parse("---\norg: globex\n---\n", "triage", context)
  end

  test "reads an agent file into the agent it declares and its definition", %{context: context} do
    text = "---\nname: triage\nuser: jon\nmodel: test:model\n---\nWatch the queue.\n"

    assert {:ok, id, %{"model" => "test:model", "instructions" => "Watch the queue."}} =
             Definition.parse(text, "file-name", context)

    assert to_string(id) == "acme/@jon/triage"

    assert {:ok, %AgentID{name: "file-name", org: "acme"}, %{}} =
             Definition.parse("", "file-name", context)

    assert {:error, "notify? is not a setting; expected one of name, org, user" <> _} =
             Definition.parse("---\nnotify?: x\n---\n", "file-name", context)
  end

  test "checks a host's defaults" do
    assert :ok =
             Definition.check_defaults(%{"model" => "test:model", "idle_timeout" => 60})

    assert {:error, "idle_timeout", "is a whole number of seconds, or infinity"} =
             Definition.check_defaults(%{"idle_timeout" => 0})

    assert :ok = Definition.check_defaults(%{"retries" => %{"attempts" => 3}})

    assert {:error, "retries", "is a set of attempts, max_wait and on_exhausted"} =
             Definition.check_defaults(%{"retries" => "often"})

    assert {:error, "retries.on_exhausted", "is ask or fail"} =
             Definition.check_defaults(%{"retries" => %{"on_exhausted" => "never"}})

    assert {:error, "name", "is not a setting; expected one of model, tools" <> _} =
             Definition.check_defaults(%{"name" => "x"})
  end

  test "changes and removes one trigger", %{id: id} do
    context = %Context{}

    {:ok, definition} =
      read(%{"triggers" => %{"every" => "1h", "prompt" => "Look."}}, context, id)

    assert {:ok, definition, :created, %WardrikTrigger{name: "sweep"}} =
             Definition.put_trigger(
               definition,
               "sweep",
               %{"every" => "2h", "prompt" => "Go."},
               context
             )

    assert [%{name: "trigger-1"}, %{name: "sweep"}] = definition.triggers

    assert {:ok, %{fields: %{"triggers" => [%{"name" => "sweep"}]}}, %{name: "trigger-1"}} =
             Definition.delete_trigger(definition, "trigger-1", context)

    assert {:error, :not_found} = Definition.delete_trigger(definition, "nope", context)

    assert {:ok, %{fields: fields}, %{name: "sweep"}} =
             Definition.delete_trigger(definition, "sweep", context)

    assert {:ok, %{fields: %{}}, %{name: "trigger-1"}} =
             Definition.delete_trigger(%{definition | fields: fields}, "trigger-1", context)
  end

  defp read!(context, id) do
    {:ok, definition} = read(%{}, context, id)
    definition
  end
end
