defmodule WardrikDaemon.AgentFileTest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent.Spec
  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.Test.Host
  alias WardrikDefinition.Record

  import Wardrik.AgentID, only: [sigil_A: 2]

  @moduletag :tmp_dir

  defmodule Hook do
    @behaviour Wardrik.Hook

    @impl true
    def init(_opts), do: nil

    @impl true
    def call(_call, _value), do: :pass
  end

  # What a definition may name here, under the sections the test has put.
  defp ctx, do: AgentFile.context(Host.config(System.tmp_dir!()))

  # The spec a definition from the defaults writes, as one sent over HTTP reads.
  defp definition(context, id, fields: fields) do
    with {:ok, record} <- Record.define(context, id, fields: fields, source: :defaults),
         do: Record.spec(record, id, context: context)
  end

  setup do
    Host.declare(["acme", "globex"])
    with_servers(linear: [transport: {:streamable_http, base_url: "https://mcp.linear.app/mcp"}])
  end

  defp read(name \\ "triage", text, context), do: read_with(name, text, context, %{})

  defp read_with(name, text, %{tmp_dir: dir}, policies) do
    path = Path.join(dir, "#{name}.md")
    File.write!(path, text)
    AgentFile.read(%{ctx() | policies: policies}, path)
  end

  test "reads a whole file into the agent's spec", context do
    assert {:ok, spec} =
             read(
               """
               ---
               description: Watches the queue.
               model: anthropic:claude-sonnet-5
               tools: [web_search, linear/*]
               org: acme
               user: jon
               timeout: 600
               max_iterations: 12
               policy: WardrikDaemon.AgentFileTest.Hook
               ---
               You watch the incident queue.
               """,
               context
             )

    assert spec.id.name == "triage"
    assert spec.id == ~A"acme/@jon/triage"
    assert spec.description == "Watches the queue."
    assert spec.config.model_spec == "anthropic:claude-sonnet-5"
    assert spec.config.system == "You watch the incident queue."
    assert spec.config.tools == [WardrikBrave.WebSearch, {WardrikMCP, :linear}]
    assert spec.config.max_iterations == 12
    assert spec.timeout == 600_000
    assert spec.hooks == [%Wardrik.Hook{name: "WardrikDaemon.AgentFileTest.Hook", module: Hook}]
    assert spec.ledger == %Wardrik.Ledger.Store{}
  end

  describe "idle_timeout" do
    test "is seconds, or infinity, and fifteen minutes where nothing sets it", context do
      assert {:ok, spec} = read("---\nidle_timeout: 60\n---\n", context)
      assert spec.idle_timeout == :timer.seconds(60)

      assert {:ok, spec} = read("---\nidle_timeout: infinity\n---\n", context)
      assert spec.idle_timeout == :infinity

      assert {:ok, spec} = read("Answer briefly.\n", context)
      assert spec.idle_timeout == :timer.minutes(15)

      assert {:error, message} = read("---\nidle_timeout: soon\n---\n", context)
      assert message =~ "idle_timeout is a whole number of seconds, or infinity"
    end

    test "is config.yaml's defaults' where the file sets none", context do
      Host.put_section(WardrikDaemon.Agents,
        defaults: %{"idle_timeout" => 300}
      )

      assert {:ok, spec} = read("Answer briefly.\n", context)
      assert spec.idle_timeout == :timer.seconds(300)

      assert {:ok, spec} = read("---\nidle_timeout: infinity\n---\n", context)
      assert spec.idle_timeout == :infinity

      assert {:ok, spec} =
               definition(ctx(), Wardrik.AgentID.parse!("acme/triage"),
                 fields: %{"timeout" => 600}
               )

      assert spec.idle_timeout == :timer.seconds(300)
    end
  end

  test "a file with no frontmatter is all prompt, and names no tools", context do
    assert {:ok, spec} = read("helper", "Answer briefly.\n", context)

    assert spec.id == ~A"default/helper"
    assert spec.config.system == "Answer briefly."
    assert spec.config.tools == []
    assert spec.hooks == []
  end

  test "* is every shipped tool, the file tools, every server it reaches, the tool workers' tools and its own operations",
       context do
    with_servers(
      linear: [transport: {:streamable_http, base_url: "https://mcp.linear.app/mcp"}],
      theirs: [transport: {:stdio, command: "theirs"}, orgs: ["globex"]],
      github: [transport: {:stdio, command: "gh"}, credential: "github"]
    )

    assert {:ok, spec} = read("---\ntools: ['*']\n---\n", context)
    {:ok, files} = WardrikWorkspace.Spec.new(~A"default/triage")

    assert spec.config.tools == [
             WardrikBrave.WebSearch,
             WardrikResearch.Deep,
             WardrikLua.Run,
             {WardrikMCP, :linear},
             {WardrikMCP, :github},
             {WardrikHTTP.Workers, ~A"default/triage"},
             {Wardrik.Catalog.Self, ~A"default/triage"},
             {Wardrik.Catalog.Agents, ~A"default/triage"},
             {WardrikWorkspace, files}
           ]

    assert {:ok, spec} = read("---\ntools: ['*']\norg: globex\n---\n", context)
    assert {WardrikMCP, :theirs} in spec.config.tools
  end

  test "an agent is refused in an org config.yaml does not declare", context do
    assert {:error, message} = read("---\norg: globx\n---\n", context)
    assert message =~ "globx is not an org config.yaml declares: default, acme, globex"
  end

  test "a server is refused to an agent of an org it does not serve", context do
    with_servers(theirs: [transport: {:stdio, command: "theirs"}, orgs: ["globex"]])

    assert {:error, message} = read("---\ntools: [theirs/*]\n---\n", context)

    assert message =~
             "tools names theirs/*, but config.yaml's theirs serves globex, and not default"

    assert {:ok, _spec} = read("---\ntools: [theirs/*]\norg: globex\n---\n", context)

    assert {:error, message} =
             definition(ctx(), Wardrik.AgentID.parse!("default/triage"),
               fields: %{
                 "tools" => ["theirs/*"]
               }
             )

    assert message =~ "serves globex, and not default"
  end

  test "carries the prices config.yaml's tools lists", context do
    Host.put_section(AgentFile, tool_prices: %{"github/*" => 0.001})

    assert {:ok, spec} = read("---\ntools: [web_search]\n---\n", context)
    assert spec.config.tool_prices == %{"github/*" => 0.001}
    assert Wardrik.LLM.Config.tool_price(spec.config, "github__create_issue") == 0.001
  end

  defp with_servers(servers),
    do: Host.put_section(WardrikMCP, servers: servers)

  describe "files" do
    test "are shared over HTTP too, within the scope of the token that sent the definition" do
      id = Wardrik.AgentID.parse!("acme/triage")

      fields = %{
        "tools" => ["files"],
        "workspace" => %{"shared" => %{"team" => "acme"}},
        "context" => ["shared/team/NOTES.md"]
      }

      assert {:ok, spec} = definition(ctx(), id, fields: fields)

      assert [{WardrikWorkspace, %WardrikWorkspace.Spec{shared: [team]} = files}] =
               spec.config.tools

      assert files.tree.tree == "agents/acme/triage"
      assert team.tree == "shared/acme"
      assert files.context == ["shared/team/NOTES.md"]

      {:ok, grant} = Wardrik.Grant.new(Wardrik.AgentID.Prefix.of(id))
      {:ok, definition} = Record.define(ctx(), id, fields: fields, source: {:api, grant})

      assert Record.spec(definition, id, context: ctx()) ==
               {:error,
                "workspace shared team: acme belongs to acme/, which acme/triage does not cover"}
    end
  end

  test "a tool nothing ships is refused", context do
    assert {:error, message} = read("---\ntools: [websearch]\n---\n", context)

    assert message =~
             "triage.md: names websearch, which is neither a tool the daemon ships nor a module"
  end

  test "a server config.yaml does not configure is refused, naming those it does", context do
    assert {:error, message} = read("---\ntools: [github/*]\n---\n", context)
    assert message =~ "configures no server github; it has linear"
  end

  test "a file may write a rule that holds after a label, and a definition may not",
       context do
    assert {:ok, spec} =
             read(
               "---\npolicy:\n  allow_after:\n    outside: [github/add_labels]\n---\n",
               context
             )

    assert [%Wardrik.Hook{value: %WardrikPolicy{rules: [rule]}}] = spec.hooks
    assert rule.after == "outside"

    assert {:error, message} =
             definition(ctx(), Wardrik.AgentID.parse!("acme/triage"),
               fields: %{
                 "policy" => %{"allow_after" => %{"outside" => ["github/add_labels"]}}
               }
             )

    assert message ==
             "policy cannot allow_after in a definition; name a policy in policies/ that does"

    careful =
      WardrikPolicy.decode!(%{"allow_after" => %{"outside" => ["github/add_labels"]}}, "careful")

    assert {:ok, _spec} =
             definition(
               %{ctx() | policies: %{"careful" => careful}},
               Wardrik.AgentID.parse!("acme/triage"),
               fields: %{"policy" => "careful"}
             )
  end

  test "a named policy is the one policies/ holds, carried as hooks", context do
    careful = WardrikPolicy.decode!(%{"deny" => ["run_lua"]}, "careful")

    assert {:ok, spec} =
             read_with("triage", "---\npolicy: careful\n---\n", context, %{"careful" => careful})

    assert spec.hooks == WardrikPolicy.hooks(careful)
  end

  test "a policy name that is neither a policy nor a module is refused", context do
    assert {:error, message} = read("---\npolicy: careful\n---\n", context)
    assert message =~ "names careful, which is neither a policy in policies/ nor a module"
  end

  # The triggers the file `text` lists, once it reads.
  defp triggered(text, %{tmp_dir: dir} = context) do
    with {:ok, _spec} <- read(text, context),
         {:ok, definition} <- AgentFile.parse(ctx(), Path.join(dir, "triage.md")),
         do: {:ok, Record.triggers(definition, context: ctx())}
  end

  test "reads one trigger, or a list of them", context do
    assert {:ok, one} =
             triggered(
               "---\ntriggers:\n  every: \"*/30 * * * *\"\n  prompt: Check the queue.\n---\n",
               context
             )

    assert [%WardrikTrigger{name: "trigger-1", every: {:cron, "*/30 * * * *"}, overlap: :skip}] =
             one

    assert {:ok, two} =
             triggered(
               """
               ---
               triggers:
                 - name: sweep
                   every: 30m
                   prompt: Check the queue.
                   jitter: 10
                 - name: digest
                   every: "0 17 * * 1-5"
                   prompt: Write up the day.
                   overlap: queue
                   missed: skip
               ---
               """,
               context
             )

    assert [
             %WardrikTrigger{name: "sweep", every: {:interval, 1_800_000}, jitter: 10_000},
             %WardrikTrigger{name: "digest", overlap: :queue, missed: :skip}
           ] = two

    assert {:ok, []} = triggered("---\n---\n", context)
  end

  # config.yaml's channels, by the orgs each serves.
  defp in_channels(orgs) do
    Host.put_section(WardrikChannel, orgs: orgs)
  end

  describe "channels" do
    setup do: in_channels(slack: ["default"], acme: ["acme"], every: :all)

    test "offers the agent in the channels it names", context do
      assert {:ok, %Spec{}} = read("---\nchannels: [slack, every]\n---\n", context)
      assert WardrikDefinition.channels(%{"channels" => ["slack"]}) == ["slack"]
      assert WardrikDefinition.channels(%{}) == []
    end

    test "refuses a channel config.yaml does not name, or keeps for another org", context do
      assert {:error, message} = read("---\nchannels: [teams]\n---\n", context)
      assert message =~ ~s(channels names "teams", but config.yaml's channels has no such channel)

      assert {:error, message} = read("---\nchannels: [acme]\n---\n", context)
      assert message =~ "channels names acme, which config.yaml keeps for another org"

      assert {:error, message} = read("---\nchannels: slack\n---\n", context)
      assert message =~ "channels is a list"
    end
  end

  describe "notify" do
    setup do
      Host.put_section(WardrikNotify,
        targets: [
          ops: {WardrikChannel.Notices, channel: {WardrikDaemon.Test.Channel, []}, room: "#ops"},
          audit: {WardrikNotify.Webhook, url: "https://hooks.test"},
          globex: {WardrikNotify.Webhook, url: "https://hooks.test/globex", orgs: ["globex"]}
        ]
      )
    end

    test "routes the agent's notices to the targets it names", %{tmp_dir: dir} = context do
      path = Path.join(dir, "triage.md")

      route = fn text ->
        File.write!(path, text)
        {:ok, definition} = AgentFile.parse(ctx(), path)
        Record.route(definition, context: ctx())
      end

      assert {:ok, %WardrikNotify.Route{targets: [:ops], on: [:parked, :failed]}} =
               route.("---\nnotify: ops\n---\n")

      assert {:ok, %WardrikNotify.Route{targets: [:ops, :audit], on: [:finished]}} =
               route.("---\nnotify: {to: [ops, audit], on: [finished]}\n---\n")

      assert :none = route.("---\n---\n")

      assert {:ok, %Spec{}} = read("---\nnotify: ops\n---\n", context)
    end

    test "routes an agent a definition over HTTP defines as a file does" do
      id = Wardrik.AgentID.parse!("acme/triage")

      {:ok, definition} =
        Record.define(ctx(), id, fields: %{"notify" => ["ops", "audit"]}, source: :defaults)

      assert {:ok, %WardrikNotify.Route{targets: [:ops, :audit], on: [:parked, :failed]}} =
               Record.route(definition, context: ctx())

      assert {:error, "notify names globex, which config.yaml's notify keeps for another org"} =
               definition(ctx(), id, fields: %{"notify" => "globex"})
    end

    test "refuses a target config.yaml does not name, and a kind that is not one", context do
      assert {:error, message} = read("---\nnotify: pager\n---\n", context)

      assert message =~
               "notify names pager, but config.yaml's notify has no target pager; it has ops, audit, globex"

      assert {:error, message} = read("---\nnotify: {to: ops, on: [started]}\n---\n", context)
      assert message =~ ~s(notify on lists "started")
    end

    test "refuses a target that tells another org's agents", context do
      assert {:error, message} = read("---\nnotify: globex\n---\n", context)
      assert message =~ "notify names globex, which config.yaml's notify keeps for another org"
      assert {:ok, _spec} = read("---\nnotify: globex\norg: globex\n---\n", context)
    end
  end

  describe "the definition schema" do
    defp schema do
      WardrikProtocol.dir()
      |> Path.join("agent_definition.json")
      |> File.read!()
      |> JSON.decode!()
    end

    # The keys a refusal says are expected.
    defp expected({:error, message}),
      do: message |> String.split("expected one of ") |> List.last() |> String.split(", ")

    test "lists the keys a definition takes, and a file takes them too, with its body as instructions",
         context do
      properties = Map.keys(schema()["properties"])

      assert Enum.sort(
               expected(
                 definition(ctx(), Wardrik.AgentID.parse!("acme/triage"), fields: %{"?" => 1})
               )
             ) ==
               Enum.sort(properties)

      assert Enum.sort(expected(read("---\n\"?\": 1\n---\n", context))) ==
               Enum.sort((properties -- ["instructions"]) ++ ~w(name org user))
    end

    test "takes its example, which the reader reads" do
      in_channels(slack: ["acme"])

      Host.put_section(WardrikNotify,
        targets: [ops: {WardrikNotify.Webhook, []}]
      )

      schema = schema()
      root = JSV.build!(schema, resolver: WardrikProtocol.Resolver)

      for example <- schema["examples"] do
        assert {:ok, _} = JSV.validate(example, root)
        assert Enum.sort(Map.keys(example)) == Enum.sort(Map.keys(schema["properties"]))

        assert {:ok, %Spec{}} =
                 definition(ctx(), Wardrik.AgentID.parse!("acme/triage"), fields: example)
      end
    end
  end

  describe "definition/3" do
    test "reads a definition into the spec of the agent under its key" do
      assert {:ok, spec} =
               definition(ctx(), Wardrik.AgentID.parse!("acme/triage"),
                 fields: %{
                   "description" => "Watches the queue.",
                   "instructions" => "You watch the incident queue.",
                   "model" => "anthropic:claude-sonnet-5",
                   "tools" => ["web_search", "linear/*"],
                   "timeout" => 600
                 }
               )

      assert spec.id == ~A"acme/triage"
      assert {spec.id.org, spec.id.user, spec.id.name} == {"acme", nil, "triage"}
      assert spec.description == "Watches the queue."
      assert spec.config.system == "You watch the incident queue."
      assert spec.config.model_spec == "anthropic:claude-sonnet-5"
      assert spec.config.tools == [WardrikBrave.WebSearch, {WardrikMCP, :linear}]
      assert spec.timeout == :timer.seconds(600)
      assert spec.ledger == %Wardrik.Ledger.Store{}
    end

    test "an empty definition is an agent with no prompt and no tools" do
      assert {:ok, spec} =
               definition(ctx(), Wardrik.AgentID.parse!("default/blank"), fields: %{})

      assert spec.config.system == nil
      assert spec.config.tools == []
    end

    test "names a policy in policies/, or writes one in place" do
      careful = WardrikPolicy.decode!(%{"deny" => ["run_lua"]}, "careful")

      assert {:ok, named} =
               definition(
                 %{
                   ctx()
                   | policies: %{
                       "careful" => careful
                     }
                 },
                 Wardrik.AgentID.parse!("acme/triage"),
                 fields: %{"policy" => "careful"}
               )

      assert named.hooks == WardrikPolicy.hooks(careful)

      assert {:ok, written} =
               definition(ctx(), Wardrik.AgentID.parse!("acme/triage"),
                 fields: %{
                   "policy" => %{"ask" => ["github/*"]}
                 }
               )

      assert [%Wardrik.Hook{module: WardrikPolicy}] = written.hooks
    end

    test "never names a module" do
      assert {:error, message} =
               definition(ctx(), Wardrik.AgentID.parse!("acme/triage"),
                 fields: %{
                   "tools" => ["WardrikLua.Run"]
                 }
               )

      assert message == "tools names WardrikLua.Run, which is not a tool the daemon ships"

      assert {:error, message} =
               definition(ctx(), Wardrik.AgentID.parse!("acme/triage"),
                 fields: %{
                   "policy" => "WardrikDaemon.AgentFileTest.Policy"
                 }
               )

      assert message ==
               "policy names WardrikDaemon.AgentFileTest.Policy, which is not a policy in policies/"
    end

    test "lists the agent's triggers as a file does, and one is set or deleted in it" do
      id = Wardrik.AgentID.parse!("acme/triage")
      unnamed = %{"every" => "1h", "prompt" => "Look."}

      assert {:ok, definition} =
               Record.define(ctx(), id,
                 fields: %{"triggers" => [unnamed, %{"every" => "1d", "prompt" => "Sum up."}]},
                 source: :defaults
               )

      assert [%WardrikTrigger{name: "trigger-1"}, %WardrikTrigger{name: "trigger-2"}] =
               Record.triggers(definition, context: ctx())

      assert {:ok, definition, :changed, %WardrikTrigger{every: {:interval, 7_200_000}}} =
               Record.put_trigger(definition, "trigger-1",
                 trigger: %{unnamed | "every" => "2h"},
                 context: ctx()
               )

      assert {:ok, definition, :created, %WardrikTrigger{name: "sweep"}} =
               Record.put_trigger(definition, "sweep", trigger: unnamed, context: ctx())

      assert ~w(trigger-1 trigger-2 sweep) ==
               Enum.map(Record.triggers(definition, context: ctx()), & &1.name)

      assert {:error, "trigger sweep: prompt is a string" <> _rest} =
               Record.put_trigger(definition, "sweep",
                 trigger: %{"every" => "1h"},
                 context: ctx()
               )

      assert {:error, "trigger sweep: prompt_file names a file" <> _rest} =
               Record.put_trigger(definition, "sweep",
                 trigger: %{"every" => "1h", "prompt_file" => "A.md"},
                 context: ctx()
               )

      {:ok, definition} = Record.delete_trigger(definition, "trigger-2")
      {:ok, definition} = Record.delete_trigger(definition, "trigger-1")
      assert {:error, :not_found} = Record.delete_trigger(definition, "trigger-1")
      {:ok, definition} = Record.delete_trigger(definition, "sweep")
      assert Record.fields(definition) == %{}

      assert {:error, "trigger 1: every: \"10s\" is shorter than a minute"} =
               definition(ctx(), id,
                 fields: %{"triggers" => %{"every" => "10s", "prompt" => "Look."}}
               )
    end

    test "answers one trigger as a list of one", context do
      {:ok, _spec} = read("---\ntriggers: {every: 1h, prompt: Look.}\n---\n", context)
      {:ok, definition} = AgentFile.parse(ctx(), Path.join(context.tmp_dir, "triage.md"))

      assert %{"triggers" => [%{"every" => "1h", "prompt" => "Look."}]} =
               Record.fields(definition)
    end

    test "takes who the agent is from its key" do
      for key <- ~w(name org user) do
        assert {:error, message} =
                 definition(ctx(), Wardrik.AgentID.parse!("acme/triage"), fields: %{key => "x"})

        assert message =~ "#{key} is not a setting; expected one of description, instructions"
      end
    end
  end

  test "frontmatter that is never closed, or is not YAML, says so", context do
    assert {:error, unclosed} = read("---\nmodel: x\n", context)
    assert unclosed =~ "never closed"

    assert {:error, yaml} = read("---\ntools: [a\n---\n", context)
    assert yaml =~ "not YAML"
  end
end
