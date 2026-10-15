defmodule WardrikDefinitionTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias WardrikDefinition.Context

  defmodule Clock do
    @behaviour Wardrik.Tool

    @impl Wardrik.Tool
    def tool,
      do:
        ReqLLM.Tool.new!(
          name: "clock",
          description: "The time.",
          callback: fn _ -> {:ok, "noon"} end
        )
  end

  defmodule Source do
    @behaviour Wardrik.Tool

    @impl Wardrik.Tool
    def tools(_argument), do: []
  end

  setup do
    {:ok, careful} = WardrikPolicy.decode(%{"ask" => ["books/*"]})

    context = %Context{
      org: "acme",
      tools: [Clock],
      servers: [books: [orgs: ["acme"]], wiki: []],
      mcp: Source,
      channels: [chat: :all, ops: ["globex"]],
      targets: [pager: {Source, orgs: :all}],
      policies: %{"careful" => careful},
      defaults: %{"idle_timeout" => 60},
      seams: [ledger: %Wardrik.Ledger.Store{}],
      names: %{host: "Mode", config: "Mode", policies: "the org's policies"}
    }

    %{context: context, id: AgentID.parse!("acme/triage")}
  end

  defp spec(fields, context, id, source \\ {:api, nil}),
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
    assert spec.config.tools == [Clock, {Source, :books}]
    assert [_hook | _hooks] = spec.hooks
    assert spec.ledger == %Wardrik.Ledger.Store{}
    assert spec.idle_timeout == :timer.seconds(60)
    assert {:ok, %{targets: [:pager]}} = WardrikDefinition.route(fields, id, context)

    assert {:ok, %{config: %{tool_prices: %{"clock" => 0.01}}}} =
             spec(%{}, %{context | config: [tool_prices: %{"clock" => 0.01}]}, id)

    assert {:ok, %{idle_timeout: :infinity}} =
             spec(%{"idle_timeout" => "infinity"}, context, id)
  end

  test "says why a definition does not read, in the host's words", %{context: context, id: id} do
    assert {:error, "tools names nope/*, but Mode configures no server nope; it has " <> _} =
             spec(%{"tools" => ["nope/*"]}, context, id)

    assert {:error, "tools names books/*, but Mode's books serves acme, and not globex"} =
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

    assert :ok = WardrikDefinition.check_defaults(%{"retries" => [1, 5, 30]})

    assert {:error, "retries", "is a list of whole numbers of seconds, one wait for each try"} =
             WardrikDefinition.check_defaults(%{"retries" => "often"})

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
