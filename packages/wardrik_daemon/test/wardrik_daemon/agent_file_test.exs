defmodule WardrikDaemon.AgentFileTest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent.Spec
  alias Wardrik.Definition
  alias Wardrik.Resource
  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.Test.Host

  import Wardrik.AgentID, only: [sigil_A: 2]

  @moduletag :tmp_dir

  # What a definition may name here, under the sections the test has put,
  # on a host with what the daemon ships, and no servers people add.
  defp ctx, do: AgentFile.context(Host.config(System.tmp_dir!()))

  defp host,
    do:
      WardrikDaemon.attach(
        Wardrik.new(store: Wardrik.Test.store()),
        Host.config(System.tmp_dir!())
      )

  # The definition `fields` write from the defaults, as one sent over HTTP reads.
  defp read_definition(context, id, fields, source \\ :defaults),
    do: Definition.read(fields, id: id, source: source, context: context)

  # The spec that definition writes.
  defp definition(context, id, fields: fields) do
    with {:ok, definition} <- read_definition(context, id, fields),
         do: Definition.spec(definition, id, context: context, host: host())
  end

  setup do
    Host.declare(["acme", "globex"])
    with_servers(linear: [transport: {:streamable_http, base_url: "https://mcp.linear.app/mcp"}])
  end

  defp read(name \\ "triage", text, context), do: read_with(name, text, context, %{})

  defp read_with(name, text, %{tmp_dir: dir}, policies) do
    path = Path.join(dir, "#{name}.md")
    File.write!(path, text)
    AgentFile.read(%{ctx() | policies: policies}, path, host: host())
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

    assert spec.config.tools == [
             WardrikBrave.WebSearch,
             {WardrikMCP, Resource.parse!("deployment/server/linear")}
           ]

    assert spec.config.max_iterations == 12
    assert spec.timeout == 600_000
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
      theirs: [
        transport: {:stdio, command: "theirs"},
        serves: [Wardrik.Resource.parse!("globex/*")]
      ],
      github: [transport: {:stdio, command: "gh"}, credential: "github"]
    )

    assert {:ok, spec} = read("---\ntools: ['*']\n---\n", context)
    {:ok, files} = WardrikWorkspace.Spec.new(~A"default/triage")

    assert spec.config.tools == [
             WardrikResearch.Deep,
             WardrikLua.Run,
             WardrikBrave.WebSearch,
             {Wardrik.Catalog.Agents, ~A"default/triage"},
             {WardrikMCP, Resource.parse!("deployment/server/github")},
             {WardrikMCP, Resource.parse!("deployment/server/linear")},
             {Wardrik.Catalog.Self, ~A"default/triage"},
             {WardrikMCP.Added, ~A"default/triage"},
             {WardrikHTTP.Workers, ~A"default/triage"},
             {WardrikWorkspace, files}
           ]

    assert {:ok, spec} = read("---\ntools: ['*']\norg: globex\n---\n", context)
    assert {WardrikMCP, Resource.parse!("deployment/server/theirs")} in spec.config.tools
  end

  test "an agent is refused in an org config.yaml does not declare", context do
    assert {:error, message} = read("---\norg: globx\n---\n", context)
    assert message =~ "globx is not an org config.yaml declares: default, acme, globex"
  end

  test "a server is refused to an agent of an org it does not serve", context do
    with_servers(
      theirs: [
        transport: {:stdio, command: "theirs"},
        serves: [Wardrik.Resource.parse!("globex/*")]
      ]
    )

    assert {:error, message} = read("---\ntools: [theirs/*]\n---\n", context)

    assert message =~ "tools names theirs/*, but theirs serves globex/*, and not default/triage"

    assert {:ok, _spec} = read("---\ntools: [theirs/*]\norg: globex\n---\n", context)

    assert {:error, message} =
             definition(ctx(), Wardrik.AgentID.parse!("default/triage"),
               fields: %{
                 "tools" => ["theirs/*"]
               }
             )

    assert message =~ "serves globex/*, and not default/triage"
  end

  test "carries the prices config.yaml's tools lists", %{tmp_dir: dir} do
    Host.put_section(AgentFile, tool_prices: %{"github/*" => 0.001})
    path = Path.join(dir, "triage.md")
    File.write!(path, "---\ntools: [web_search]\n---\n")
    host = WardrikDaemon.host(Host.config(dir), store: Wardrik.Test.store())

    assert {:ok, spec} = AgentFile.read(ctx(), path, host: host)
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

      token = %Wardrik.Token{
        principal: Wardrik.Principal.new(:user, "jon"),
        scope: [Wardrik.Role.bind([:owner], [Wardrik.AgentID.resource(id)])]
      }

      {:ok, definition} = read_definition(ctx(), id, fields, {:api, token})

      assert Definition.spec(definition, id, context: ctx(), host: host()) ==
               {:error,
                "workspace shared team: acme belongs to acme/agent/*, which the token does not reach"}
    end
  end

  test "a tool nothing ships is refused", context do
    assert {:error, message} = read("---\ntools: [websearch]\n---\n", context)

    assert message =~ "triage.md: tools names websearch, which is not a tool the daemon ships"
  end

  test "a server config.yaml does not configure is refused, naming those it does", context do
    assert {:error, message} = read("---\ntools: [github/*]\n---\n", context)

    assert message =~
             "tools names github/*, but the daemon has no github/*; it has agents/*, linear/*"
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

  test "a policy name that is not a policy is refused, a module's too", context do
    assert {:error, message} = read("---\npolicy: careful\n---\n", context)
    assert message =~ "policy names careful, which is not a policy in policies/"

    assert {:error, message} = read("---\npolicy: WardrikPolicy.Budget\n---\n", context)
    assert message =~ "policy names WardrikPolicy.Budget, which is not a policy in policies/"
  end

  # The triggers the file `text` lists, once it reads.
  defp triggered(text, %{tmp_dir: dir} = context) do
    with {:ok, _spec} <- read(text, context),
         {:ok, definition} <- AgentFile.parse(ctx(), Path.join(dir, "triage.md")),
         do: {:ok, definition.triggers}
  end

  test "reads one trigger, or a list of them", context do
    assert {:ok, one} =
             triggered(
               "---\ntriggers:\n  every: \"*/30 * * * *\"\n  prompt: Check the queue.\n---\n",
               context
             )

    assert [
             %WardrikTrigger{
               name: "trigger-1",
               every: %WardrikTrigger.Cron{source: "*/30 * * * *"},
               overlap: :skip
             }
           ] =
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
             %WardrikTrigger{
               name: "sweep",
               every: %WardrikTrigger.Interval{ms: 1_800_000},
               jitter: 10_000
             },
             %WardrikTrigger{name: "digest", overlap: :queue, missed: :skip}
           ] = two

    assert {:ok, []} = triggered("---\n---\n", context)
  end

  test "offers the agent in the channels it names, by name", %{tmp_dir: dir} = context do
    assert {:ok, %Spec{}} = read("---\nchannels: [slack, teams]\n---\n", context)
    {:ok, definition} = AgentFile.parse(ctx(), Path.join(dir, "triage.md"))
    assert definition.channels == ["slack", "teams"]

    assert {:error, message} = read("---\nchannels: slack\n---\n", context)
    assert message =~ "channels is a list"
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
        definition.notify
      end

      assert %WardrikNotify.Route{targets: ["ops"], on: [:parked, :failed]} =
               route.("---\nnotify: ops\n---\n")

      assert %WardrikNotify.Route{targets: ["ops", "audit"], on: [:finished]} =
               route.("---\nnotify: {to: [ops, audit], on: [finished]}\n---\n")

      assert nil == route.("---\n---\n")

      assert {:ok, %Spec{}} = read("---\nnotify: ops\n---\n", context)
    end

    test "routes an agent a definition over HTTP defines as a file does" do
      id = Wardrik.AgentID.parse!("acme/triage")

      {:ok, definition} = read_definition(ctx(), id, %{"notify" => ["ops", "audit"]})

      assert %WardrikNotify.Route{targets: ["ops", "audit"], on: [:parked, :failed]} =
               definition.notify
    end

    test "refuses a kind that is not one", context do
      assert {:error, message} = read("---\nnotify: {to: ops, on: [started]}\n---\n", context)
      assert message =~ ~s(notify on lists "started")
    end

    test "names a target kept for another org, which tells its agents nothing", context do
      assert {:ok, _spec} = read("---\nnotify: globex\n---\n", context)
      targets = Keyword.fetch!(Host.sections()[WardrikNotify], :targets)
      refute WardrikNotify.tells?(targets, "globex", "default")
      assert WardrikNotify.tells?(targets, "globex", "globex")
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

      assert spec.config.tools == [
               WardrikBrave.WebSearch,
               {WardrikMCP, Resource.parse!("deployment/server/linear")}
             ]

      assert spec.timeout == :timer.seconds(600)
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
               read_definition(ctx(), id, %{
                 "triggers" => [unnamed, %{"every" => "1d", "prompt" => "Sum up."}]
               })

      assert [%WardrikTrigger{name: "trigger-1"}, %WardrikTrigger{name: "trigger-2"}] =
               definition.triggers

      assert {:ok, definition, :changed,
              %WardrikTrigger{every: %WardrikTrigger.Interval{ms: 7_200_000}}} =
               Definition.put_trigger(
                 definition,
                 "trigger-1",
                 %{unnamed | "every" => "2h"},
                 ctx()
               )

      assert {:ok, definition, :created, %WardrikTrigger{name: "sweep"}} =
               Definition.put_trigger(definition, "sweep", unnamed, ctx())

      assert ~w(trigger-1 trigger-2 sweep) == Enum.map(definition.triggers, & &1.name)

      assert {:error, "trigger sweep: prompt is a string" <> _rest} =
               Definition.put_trigger(definition, "sweep", %{"every" => "1h"}, ctx())

      assert {:error, "trigger sweep: prompt_file names a file" <> _rest} =
               Definition.put_trigger(
                 definition,
                 "sweep",
                 %{"every" => "1h", "prompt_file" => "A.md"},
                 ctx()
               )

      {:ok, definition, _trigger} = Definition.delete_trigger(definition, "trigger-2", ctx())
      {:ok, definition, _trigger} = Definition.delete_trigger(definition, "trigger-1", ctx())
      assert {:error, :not_found} = Definition.delete_trigger(definition, "trigger-1", ctx())
      {:ok, definition, _trigger} = Definition.delete_trigger(definition, "sweep", ctx())
      assert definition.fields == %{}

      assert {:error, "trigger 1: every: \"10s\" is shorter than a minute"} =
               definition(ctx(), id,
                 fields: %{"triggers" => %{"every" => "10s", "prompt" => "Look."}}
               )
    end

    test "answers one trigger as a list of one", context do
      {:ok, _spec} = read("---\ntriggers: {every: 1h, prompt: Look.}\n---\n", context)
      {:ok, definition} = AgentFile.parse(ctx(), Path.join(context.tmp_dir, "triage.md"))

      assert %{"triggers" => [%{"every" => "1h", "prompt" => "Look."}]} = definition.fields
    end

    test "takes who the agent is from its key" do
      for key <- ~w(name org user) do
        assert {:error, message} =
                 definition(ctx(), Wardrik.AgentID.parse!("acme/triage"), fields: %{key => "x"})

        assert message =~
                 "#{key} is not a setting; expected one of display_name, description, instructions"
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
