defmodule WardrikDefinition.ReadingTest do
  use ExUnit.Case, async: true

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.Servers.Key
  alias WardrikDefinition.Context

  import Wardrik.AgentID, only: [sigil_A: 2]

  defmodule Hook do
    @behaviour Wardrik.Hook

    @impl true
    def init(_opts), do: nil

    @impl true
    def call(_call, _value), do: :pass
  end

  defmodule Search do
    @behaviour Wardrik.Tool

    @impl Wardrik.Tool
    def tool,
      do: ReqLLM.Tool.new!(name: "web_search", description: "Searches.", callback: &{:ok, &1})
  end

  defmodule Lua do
    @behaviour Wardrik.Tool

    @impl Wardrik.Tool
    def tool,
      do: ReqLLM.Tool.new!(name: "run_lua", description: "Runs Lua.", callback: &{:ok, &1})
  end

  defmodule Source do
    @behaviour Wardrik.Tool

    @impl Wardrik.Tool
    def tools(_argument), do: []
  end

  setup do
    %{
      context: %Context{
        tools: [Search, Lua],
        servers: [linear: [], theirs: [serves: [Wardrik.AgentID.Prefix.tenant!("globex")]]],
        mcp: Source,
        sources: [workers: Source, self: Wardrik.Catalog.Self, agents: Wardrik.Catalog.Agents],
        channels: [slack: ["default"], acme: ["acme"], every: :all],
        targets: [
          ops: {Source, []},
          audit: {Source, []},
          globex: {Source, orgs: ["globex"]}
        ],
        names: %{host: "the daemon", config: "config.yaml", policies: "policies/"}
      }
    }
  end

  # The spec an agent file `text` named `name` writes, as an operator's file.
  defp read(name \\ "triage", text, %{context: context}) do
    with {:ok, id, fields} <- WardrikDefinition.parse(text, name, context),
         do: WardrikDefinition.spec(fields, id, id, context, {:file, name})
  end

  defp with_policies(%{context: context}, policies),
    do: %{context: %{context | policies: policies}}

  # The spec a definition sent to the HTTP API writes for `id`, sent by no token.
  defp define(id, fields, %{context: context}) do
    with :ok <- WardrikDefinition.accept(id, fields, context),
         do: WardrikDefinition.spec(fields, id, id, context, :defaults)
  end

  # Where the notices of the agent a file `text` declares go, once the file reads.
  defp route(text, %{context: context} = test) do
    with {:ok, _spec} <- read(text, test),
         {:ok, id, fields} <- WardrikDefinition.parse(text, "triage", context),
         do: WardrikDefinition.route(fields, id, context)
  end

  defp triggers(text, %{context: context} = test) do
    with {:ok, _spec} <- read(text, test),
         {:ok, _id, fields} <- WardrikDefinition.parse(text, "triage", context),
         do: {:ok, WardrikDefinition.triggers(fields, %WardrikDefinition.Context{})}
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
               policy: WardrikDefinition.ReadingTest.Hook
               ---
               You watch the incident queue.
               """,
               context
             )

    assert spec.id == ~A"acme/@jon/triage"
    assert spec.description == "Watches the queue."
    assert spec.config.model_spec == "anthropic:claude-sonnet-5"
    assert spec.config.system == "You watch the incident queue."
    assert spec.config.tools == [Search, {Source, Key.deployment("linear")}]
    assert spec.config.max_iterations == 12
    assert spec.timeout == 600_000
    assert spec.hooks == [%Wardrik.Hook{name: "WardrikDefinition.ReadingTest.Hook", module: Hook}]
  end

  test "idle_timeout is seconds or infinity, and the defaults' where it sets none", context do
    assert {:ok, %{idle_timeout: 60_000}} = read("---\nidle_timeout: 60\n---\n", context)
    assert {:ok, %{idle_timeout: :infinity}} = read("---\nidle_timeout: infinity\n---\n", context)
    assert {:ok, %{idle_timeout: 900_000}} = read("Answer briefly.\n", context)

    assert {:error, "idle_timeout is a whole number of seconds, or infinity"} =
             read("---\nidle_timeout: soon\n---\n", context)

    defaults = %{context: %{context.context | defaults: %{"idle_timeout" => 300}}}
    assert {:ok, %{idle_timeout: 300_000}} = read("Answer briefly.\n", defaults)

    assert {:ok, %{idle_timeout: :infinity}} =
             read("---\nidle_timeout: infinity\n---\n", defaults)
  end

  test "retries are seconds before each try, and the defaults' where it sets none", context do
    assert {:ok, spec} = read("---\nretries: [2, 10, 30]\n---\n", context)
    assert spec.config.retries == [2_000, 10_000, 30_000]
    assert {:ok, %{config: %{retries: []}}} = read("---\nretries: []\n---\n", context)
    assert {:ok, %{config: %{retries: [1_000, 5_000]}}} = read("Answer briefly.\n", context)

    for written <- ["soon", "[1, -1]", "[1.5]"] do
      assert {:error, "retries is a list of whole numbers of seconds, one wait for each try"} =
               read("---\nretries: #{written}\n---\n", context)
    end

    defaults = %{context: %{context.context | defaults: %{"retries" => [3]}}}
    assert {:ok, %{config: %{retries: [3_000]}}} = read("Answer briefly.\n", defaults)
    assert {:ok, %{config: %{retries: []}}} = read("---\nretries: []\n---\n", defaults)
  end

  test "text/1 writes a file that reads back as it was given", context do
    text =
      WardrikDefinition.text([
        {"org", "acme"},
        {"description", "Says what it does."},
        {"model", "anthropic:claude-sonnet-5"},
        {"tools", ["web_search"]},
        {"policy", %{"ask" => ["linear/*"]}},
        {"timeout", 600},
        {"name", "yes"}
      ])

    assert text =~ "\norg: acme\ndescription: \"Says what it does.\"\nmodel: anthropic:"
    assert text =~ "\ntools: [web_search]\npolicy: {ask: [linear/*]}\n"
    assert text =~ "\nname: \"yes\"\n---\nYou are a helpful assistant."
    assert {:ok, spec} = read("written", text, context)
    assert spec.id == ~A"acme/yes"
    assert spec.config.tools == [Search]
    assert spec.timeout == 600_000
  end

  test "text/2 writes the prompt it is given, and quotes what YAML would misread", context do
    text =
      WardrikDefinition.text(
        [
          {"tools", ["files"]},
          {"context", ["MEMORY.md", "a: b", "yes"]},
          {"policy", %{"budget" => %{"tokens" => 1000, "per" => "day"}}}
        ],
        "You take requests.\n\n"
      )

    assert text == ~S"""
           ---
           tools: [files]
           context: [MEMORY.md, "a: b", "yes"]
           policy: {budget: {per: day, tokens: 1000}}
           ---
           You take requests.
           """

    assert {:ok, spec} = read("written", text, context)
    assert spec.config.system == "You take requests."
  end

  test "a file with no frontmatter is all prompt, and names no tools", context do
    assert {:ok, spec} = read("helper", "Answer briefly.\n", context)
    assert spec.id == ~A"default/helper"
    assert spec.config.system == "Answer briefly."
    assert {spec.config.tools, spec.hooks} == {[], []}

    assert {:ok, %{id: ~A"default/triage"}} =
             read("file-name", "---\nname: triage\n---\n", context)
  end

  test "* is every shipped tool, the file tools, every server it reaches and every source's tools",
       context do
    assert {:ok, spec} = read("---\ntools: ['*']\n---\n", context)
    {:ok, files} = WardrikWorkspace.Spec.new(~A"default/triage")

    assert spec.config.tools == [
             Search,
             Lua,
             {Source, Key.deployment("linear")},
             {Source, ~A"default/triage"},
             {Wardrik.Catalog.Self, ~A"default/triage"},
             {Wardrik.Catalog.Agents, ~A"default/triage"},
             {WardrikWorkspace, files}
           ]

    assert {:ok, spec} = read("---\ntools: ['*']\norg: globex\n---\n", context)
    assert {Source, Key.deployment("theirs")} in spec.config.tools
  end

  test "a server is refused to an agent of an org it does not serve", context do
    assert {:error,
            "tools names theirs/*, but config.yaml's theirs serves globex/*, and not default/triage"} =
             read("---\ntools: [theirs/*]\n---\n", context)

    assert {:ok, _spec} = read("---\ntools: [theirs/*]\norg: globex\n---\n", context)
  end

  describe "files" do
    test "are the file tools over the agent's own tree, and the trees workspace shares",
         context do
      assert {:ok, spec} =
               read(
                 """
                 ---
                 org: acme
                 tools: [files]
                 workspace:
                   shared:
                     team: acme
                     runbooks: {tree: acme/runbooks, mode: read}
                 ---
                 """,
                 context
               )

      assert [{WardrikWorkspace, %WardrikWorkspace.Spec{} = files}] = spec.config.tools
      assert files.tree.tree == "agents/acme/triage"

      assert Enum.map(files.shared, &{&1.name, &1.tree, &1.mode}) == [
               {"runbooks", "shared/acme/runbooks", :read},
               {"team", "shared/acme", :write}
             ]
    end

    test "share a tree another owns where the host shares it with the agent", %{context: context} do
      text = """
      ---
      org: acme
      user: jon
      tools: [files]
      workspace:
        shared:
          runbooks: {tree: acme/runbooks, mode: read}
      ---
      """

      assert {:error, message} = read(text, %{context: context})
      assert message =~ "acme/runbooks belongs to acme/"

      {:ok, share} = WardrikWorkspace.Share.new("acme/runbooks", read: ["acme/*"])
      assert {:ok, spec} = read(text, %{context: %{context | shares: [share]}})
      assert [{WardrikWorkspace, %WardrikWorkspace.Spec{shared: [runbooks]}}] = spec.config.tools
      assert {runbooks.tree, runbooks.mode} == {"shared/acme/runbooks", :read}
    end

    test "share no tree the agent's key does not reach", context do
      assert {:error, message} =
               read(
                 "---\norg: acme\ntools: [files]\nworkspace: {shared: {theirs: globex}}\n---\n",
                 context
               )

      assert message =~
               "workspace shared theirs: globex belongs to globex/, which acme/triage is not under"
    end

    test "are what a workspace needs, and a workspace takes only shared", context do
      assert {:error, message} = read("---\nworkspace: {shared: {team: _}}\n---\n", context)
      assert message =~ "workspace shares trees, and tools names no files"

      assert {:error, "workspace.size is not a setting; expected shared"} =
               read("---\ntools: [files]\nworkspace: {size: 1GB}\n---\n", context)

      assert {:error, "workspace is a set of settings: shared"} =
               read("---\ntools: [files]\nworkspace: [team]\n---\n", context)
    end

    test "are shared over HTTP too, within the scope of the token that sent the definition",
         %{context: context} = test do
      id = AgentID.parse!("acme/triage")

      fields = %{
        "tools" => ["files"],
        "workspace" => %{"shared" => %{"team" => "acme"}},
        "context" => ["shared/team/NOTES.md"]
      }

      assert {:ok, spec} = define(id, fields, test)

      assert [{WardrikWorkspace, %WardrikWorkspace.Spec{shared: [team]} = files}] =
               spec.config.tools

      assert {files.tree.tree, team.tree} == {"agents/acme/triage", "shared/acme"}
      assert files.context == ["shared/team/NOTES.md"]

      {:ok, grant} = Wardrik.Grant.new(Wardrik.AgentID.Prefix.of(id))

      assert WardrikDefinition.spec(fields, id, id, context, {:api, grant}) ==
               {:error,
                "workspace shared team: acme belongs to acme/, which acme/triage does not cover"}
    end
  end

  test "a source's name and /* is every tool it offers the agent", context do
    assert {:ok, spec} =
             read("---\norg: acme\ntools: [workers/*, self/*, agents/*]\n---\n", context)

    assert spec.config.tools == [
             {Source, ~A"acme/triage"},
             {Wardrik.Catalog.Self, ~A"acme/triage"},
             {Wardrik.Catalog.Agents, ~A"acme/triage"}
           ]

    assert {:error, message} = read("---\ntools: [workers/refund]\n---\n", context)

    assert message =~
             "name the source's tools as workers/*, and let a policy deny what is not refund"
  end

  test "a tool, server or key nothing provides is refused, saying what does", context do
    assert {:error, "names websearch, which is neither a tool the daemon ships nor a module"} =
             read("---\ntools: [websearch]\n---\n", context)

    assert {:error,
            "tools names github/*, but config.yaml configures no server github; it has " <> _} =
             read("---\ntools: [github/*]\n---\n", context)

    assert {:error, "tools names github/*, but config.yaml configures no server github"} =
             read("---\ntools: [github/*]\n---\n", %{context: %{context.context | servers: []}})

    assert {:error, message} = read("---\ntools: [linear/list_issues]\n---\n", context)
    assert message =~ "name the whole server as linear/*, and list list_issues in its only"

    assert {:error, "mcp is not a setting; expected one of " <> _} =
             read("---\nmcp: [linear]\n---\n", context)

    assert {:error, "tools is a list"} = read("---\ntools: web_search\n---\n", context)

    assert {:error, "tools names 1, which is not a tool"} =
             read("---\ntools: [1]\n---\n", context)

    assert {:error,
            "tools names run_lua(x); name the tool alone, and let a policy name what its calls act on"} =
             read("---\ntools: [run_lua(x)]\n---\n", context)
  end

  test "a file may write a rule that holds after a label, and a definition may not", context do
    assert {:ok, spec} =
             read(
               "---\npolicy:\n  allow_after:\n    outside: [github/add_labels]\n---\n",
               context
             )

    assert [%Wardrik.Hook{value: %WardrikPolicy{rules: [rule]}}] = spec.hooks
    assert rule.after == "outside"

    assert {:error,
            "policy cannot allow_after in a definition; name a policy in policies/ that does"} =
             define(
               ~A"acme/triage",
               %{"policy" => %{"allow_after" => %{"outside" => ["github/add_labels"]}}},
               context
             )

    careful =
      WardrikPolicy.decode!(%{"allow_after" => %{"outside" => ["github/add_labels"]}}, "careful")

    assert {:ok, _spec} =
             define(
               ~A"acme/triage",
               %{"policy" => "careful"},
               with_policies(context, %{"careful" => careful})
             )
  end

  test "a policy is one policies/ names, rules written in place, or a module", context do
    careful = WardrikPolicy.decode!(%{"deny" => ["run_lua"]}, "careful")

    assert {:ok, spec} =
             read("---\npolicy: careful\n---\n", with_policies(context, %{"careful" => careful}))

    assert spec.hooks == WardrikPolicy.hooks(careful)

    assert {:ok, spec} = read("---\npolicy:\n  ask: [github/*]\n---\n", context)
    assert [%Wardrik.Hook{module: WardrikPolicy, value: policy}] = spec.hooks
    assert {:ask, _prompt} = WardrikPolicy.decide(policy, "github__create_issue")

    assert {:ok, spec} = read("---\npolicy:\n  budget:\n    usd: 5\n---\n", context)

    assert [
             %Wardrik.Hook{module: WardrikPolicy},
             %Wardrik.Hook{module: WardrikPolicy.Budget, value: %WardrikPolicy.Budget{usd: 5.0}}
           ] = spec.hooks

    assert {:error, "policy allows is not a setting" <> _} =
             read("---\npolicy:\n  allows: [x]\n---\n", context)

    assert {:error, "names careful, which is neither a policy in policies/ nor a module"} =
             read("---\npolicy: careful\n---\n", context)

    assert {:error, "WardrikDefinition.ReadingTest is not a hook"} =
             read("---\npolicy: WardrikDefinition.ReadingTest\n---\n", context)

    assert {:error, "policy is the name of a policy, rules, or a module"} =
             read("---\npolicy: [x]\n---\n", context)
  end

  test "a policy written in place may hold conditions on a call's arguments", context do
    assert {:ok, spec} =
             read(
               """
               ---
               policy:
                 deny:
                   write_file(content = *password*): No secrets in files.
                 ask: ["books/create_bill(amount >= 100, account != Payroll)"]
               ---
               """,
               context
             )

    assert [%Wardrik.Hook{module: WardrikPolicy, value: policy}] = spec.hooks

    assert {:deny, "No secrets in files."} =
             WardrikPolicy.decide(policy, "write_file", [], %{"content" => "the password"})

    assert {:ask, _prompt} =
             WardrikPolicy.decide(policy, "books__create_bill", [], %{
               "amount" => 500,
               "account" => "Rent"
             })
  end

  test "compaction is on by default, tuned or turned off", context do
    assert {:ok, default} = read("---\n---\n", context)
    assert default.config.history == {Wardrik.Compaction, %Wardrik.Compaction{}}

    assert {:ok, tuned} = read("---\ncompaction:\n  at: 0.5\n  window: 32000\n---\n", context)

    assert tuned.config.history ==
             {Wardrik.Compaction, %Wardrik.Compaction{at: 0.5, keep: 0.25, window: 32_000}}

    assert {:ok, %{config: %{history: nil}}} = read("---\ncompaction: false\n---\n", context)

    for {settings, refusal} <- [
          {"{at: 2}", "compaction at is a share of the window, between 0 and 1"},
          {"{at: 0.3, keep: 0.4}", "a compaction keeps less than it waits for"},
          {"{window: -1}", "compaction window is a whole number of tokens"},
          {"{every: 1}", "compaction every is not a setting; expected at, keep or window"},
          {"often", "compaction is false, or a set of at, keep and window"}
        ] do
      assert {:error, message} = read("---\ncompaction: #{settings}\n---\n", context)
      assert message =~ refusal
    end
  end

  test "scalars that do not read say why", context do
    for {settings, refusal} <- [
          {"timeout: soon", "timeout is a whole number of seconds"},
          {"max_iterations: 0", "max_iterations is a whole number, or infinity"},
          {"model: 5", "model is a string"},
          {"description: [a]", "description is a string"}
        ] do
      assert {:error, ^refusal} = read("---\n#{settings}\n---\n", context)
    end

    assert {:ok, %{config: %{max_iterations: :infinity}}} =
             read("---\nmax_iterations: infinity\n---\n", context)
  end

  test "reads one trigger, or a list of them", context do
    assert {:ok,
            [
              %WardrikTrigger{
                name: "trigger-1",
                every: %WardrikTrigger.Cron{source: "*/30 * * * *"}
              }
            ]} =
             triggers(
               "---\ntriggers:\n  every: \"*/30 * * * *\"\n  prompt: Look.\n---\n",
               context
             )

    assert {:ok, two} =
             triggers(
               """
               ---
               triggers:
                 - name: sweep
                   every: 30m
                   prompt: Check the queue.
                   jitter: 10
                 - name: digest
                   every: "0 17 * * 1-5"
                   timezone: Europe/Berlin
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
             %WardrikTrigger{
               name: "digest",
               every: %WardrikTrigger.Cron{timezone: berlin},
               overlap: :queue,
               missed: :skip
             }
           ] = two

    assert to_string(berlin) == "Europe/Berlin"

    assert {:ok, []} = triggers("---\n---\n", context)
  end

  test "a trigger that does not read says which and why", context do
    for {settings, refusal} <- [
          {"{every: 10s, prompt: Look.}", "trigger 1: every: \"10s\" is shorter than a minute"},
          {"{name: sweep, every: 30m}", "trigger sweep: prompt is a string"},
          {"{name: sweep, every: 30m, timezone: Europe/Berlin, prompt: Look.}",
           ~s(trigger sweep: timezone applies to a cron expression; every: "30m" counts elapsed time)},
          {"{every: 30m, prompt: Look., when: now}", "trigger when is not a setting"},
          {"[{name: a, every: 30m, prompt: x}, {name: a, every: 1h, prompt: y}]",
           "trigger names a twice"},
          {"[look]", "trigger 1 is not a set of keys"},
          {"look", "triggers is a trigger, or a list of them"}
        ] do
      assert {:error, message} = read("---\ntriggers: #{settings}\n---\n", context)
      assert message =~ refusal
    end
  end

  test "prompt_file asks the agent to follow a file of its workspace when the trigger fires",
       context do
    assert {:ok, [%WardrikTrigger{name: "heartbeat", prompt: prompt}]} =
             triggers(
               "---\ntools: [files]\ntriggers: {name: heartbeat, every: 30m, prompt_file: ./HEARTBEAT.md}\n---\n",
               context
             )

    assert prompt =~ "It is time for heartbeat. Read HEARTBEAT.md with read_file"

    for {settings, refusal} <- [
          {"tools: [files]\ntriggers: {every: 30m, prompt: Look., prompt_file: H.md}",
           "a trigger has a prompt or a prompt_file, not both"},
          {"triggers: {every: 30m, prompt_file: H.md}",
           "prompt_file names a file, and tools names no files to read it with"},
          {"tools: [files]\ntriggers: {every: 30m, prompt_file: /etc/passwd}",
           "prompt_file: /etc/passwd is absolute"}
        ] do
      assert {:error, message} = read("---\n#{settings}\n---\n", context)
      assert message =~ refusal
    end
  end

  test "channels are the ones the host names for the agent's org", context do
    assert {:ok, %Spec{}} = read("---\nchannels: [slack, every]\n---\n", context)
    assert WardrikDefinition.channels(%{"channels" => ["slack"]}) == ["slack"]
    assert WardrikDefinition.channels(%{}) == []

    assert {:error, ~s(channels names "teams", but config.yaml's channels has no such channel)} =
             read("---\nchannels: [teams]\n---\n", context)

    assert {:error, "channels names acme, which config.yaml keeps for another org"} =
             read("---\nchannels: [acme]\n---\n", context)

    assert {:error, "channels is a list of the channels it is offered in"} =
             read("---\nchannels: slack\n---\n", context)
  end

  test "notify routes the agent's notices to targets the host names for its org", context do
    assert {:ok, %WardrikNotify.Route{targets: [:ops], on: [:parked, :failed]}} =
             route("---\nnotify: ops\n---\n", context)

    assert {:ok, %WardrikNotify.Route{targets: [:ops, :audit], on: [:finished]}} =
             route("---\nnotify: {to: [ops, audit], on: [finished]}\n---\n", context)

    assert :none = route("---\n---\n", context)

    for {settings, refusal} <- [
          {"pager",
           "notify names pager, but config.yaml's notify has no target pager; it has ops, audit, globex"},
          {"{to: ops, on: [started]}", ~s(notify on lists "started")},
          {"globex", "notify names globex, which config.yaml's notify keeps for another org"},
          {"{to: []}", "notify names no target"},
          {"{to: ops, when: now}", "notify when is not a setting; expected to or on"},
          {"[1]", "notify names 1, which is not a target"},
          {"5", "notify is a target, a list of them, or to and on"}
        ] do
      assert {:error, message} = route("---\nnotify: #{settings}\n---\n", context)
      assert message =~ refusal
    end

    assert {:ok, _route} = route("---\nnotify: globex\norg: globex\n---\n", context)

    assert {:error, "notify names ops, but the host's notify has no target ops"} =
             route("---\nnotify: ops\n---\n", %{context: %Context{}})
  end

  describe "a definition sent to the HTTP API" do
    test "reads into the spec of the agent under its key", context do
      assert {:ok, spec} =
               define(
                 ~A"acme/triage",
                 %{
                   "description" => "Watches the queue.",
                   "instructions" => "You watch the incident queue.",
                   "model" => "anthropic:claude-sonnet-5",
                   "tools" => ["web_search", "linear/*"],
                   "timeout" => 600
                 },
                 context
               )

      assert spec.id == ~A"acme/triage"
      assert spec.config.system == "You watch the incident queue."
      assert spec.config.tools == [Search, {Source, Key.deployment("linear")}]
      assert spec.timeout == :timer.seconds(600)

      assert {:ok, %{config: %{system: nil, tools: []}}} = define(~A"default/blank", %{}, context)
    end

    test "never names a module", context do
      assert {:error, "tools names WardrikLua.Run, which is not a tool the daemon ships"} =
               define(~A"acme/triage", %{"tools" => ["WardrikLua.Run"]}, context)

      assert {:error, "policy names Elixir.Kernel, which is not a policy in policies/"} =
               define(~A"acme/triage", %{"policy" => "Elixir.Kernel"}, context)
    end

    test "takes who the agent is from its key, and says why it does not read", context do
      for key <- ~w(name org user) do
        assert {:error, message} = define(~A"acme/triage", %{key => "x"}, context)
        assert message =~ "#{key} is not a setting; expected one of description, instructions"
      end

      assert {:error, "timeout is a whole number of seconds"} =
               define(~A"acme/triage", %{"timeout" => "soon"}, context)

      assert {:error, "instructions is a string"} =
               define(~A"acme/triage", %{"instructions" => ["a"]}, context)

      assert {:error, "acme/other is neither acme/triage nor a conversation of it"} =
               WardrikDefinition.spec(
                 %{},
                 ~A"acme/triage",
                 ~A"acme/other",
                 context.context,
                 :defaults
               )
    end

    test "routes its notices as a file does, to targets that serve its org", context do
      fields = %{"notify" => %{"to" => ["ops"], "on" => ["finished"]}}
      assert {:ok, _spec} = define(~A"acme/triage", fields, context)

      assert {:ok, %WardrikNotify.Route{targets: [:ops], on: [:finished]}} =
               WardrikDefinition.route(fields, ~A"acme/triage", context.context)

      assert {:error, "notify names globex, which config.yaml's notify keeps for another org"} =
               define(~A"acme/triage", %{"notify" => "globex"}, context)

      assert {:ok, _spec} = define(~A"globex/triage", %{"notify" => ["globex"]}, context)
    end

    test "lists its triggers as a file does, and one is set or deleted in it" do
      unnamed = %{"every" => "1h", "prompt" => "Look."}
      fields = %{"triggers" => [unnamed, %{"every" => "1d", "prompt" => "Sum up."}]}

      assert [%WardrikTrigger{name: "trigger-1"}, %WardrikTrigger{name: "trigger-2"}] =
               WardrikDefinition.triggers(fields, %WardrikDefinition.Context{})

      assert {:ok, fields, :changed,
              %WardrikTrigger{every: %WardrikTrigger.Interval{ms: 7_200_000}}} =
               WardrikDefinition.put_trigger(fields, "trigger-1",
                 trigger: %{unnamed | "every" => "2h"},
                 context: %WardrikDefinition.Context{}
               )

      assert {:ok, fields, :created, %WardrikTrigger{name: "sweep"}} =
               WardrikDefinition.put_trigger(fields, "sweep",
                 trigger: unnamed,
                 context: %WardrikDefinition.Context{}
               )

      assert ~w(trigger-1 trigger-2 sweep) ==
               Enum.map(
                 WardrikDefinition.triggers(fields, %WardrikDefinition.Context{}),
                 & &1.name
               )

      assert {:error, "trigger sweep: prompt is a string" <> _rest} =
               WardrikDefinition.put_trigger(fields, "sweep",
                 trigger: %{"every" => "1h"},
                 context: %WardrikDefinition.Context{}
               )

      {:ok, fields} = WardrikDefinition.delete_trigger(fields, "trigger-2")
      {:ok, fields} = WardrikDefinition.delete_trigger(fields, "trigger-1")
      assert {:error, :not_found} = WardrikDefinition.delete_trigger(fields, "trigger-1")
      {:ok, fields} = WardrikDefinition.delete_trigger(fields, "sweep")
      assert WardrikDefinition.fields(fields) == %{}

      assert %{"triggers" => [%{"every" => "1h"}], "notify" => "ops"} =
               WardrikDefinition.fields(%{"triggers" => unnamed, "notify" => "ops"})
    end
  end

  test "frontmatter that is never closed, or is not YAML, says so", context do
    assert {:error, "has frontmatter that is never closed with ---"} =
             read("---\nmodel: x\n", context)

    assert {:error, "has frontmatter that is not YAML: " <> _} =
             read("---\ntools: [a\n---\n", context)

    assert {:error, "has frontmatter that is not a set of keys"} =
             read("---\n- a\n---\n", context)

    assert {:error, "name is a string"} = read("---\nname: [a]\n---\n", context)
    assert {:error, _message} = read("---\nname: a/b\n---\n", context)
  end

  describe "context" do
    test "names files read into each turn, in the workspace the file tools reach", context do
      assert {:ok, spec} =
               read(
                 "---\norg: acme\ntools: [files]\nworkspace: {shared: {team: acme}}\ncontext: [SOUL.md, shared/team/CONVENTIONS.md]\n---\n",
                 context
               )

      assert [{WardrikWorkspace, %WardrikWorkspace.Spec{context: files}}] = spec.config.tools
      assert files == ["SOUL.md", "shared/team/CONVENTIONS.md"]
    end

    test "takes the files with how much of them each turn reads", context do
      assert {:ok, spec} =
               read(
                 "---\ntools: [files]\ncontext: {files: [MEMORY.md], max_bytes: 65536}\n---\n",
                 context
               )

      assert [{WardrikWorkspace, %WardrikWorkspace.Spec{} = files}] = spec.config.tools
      assert {files.context, files.context_bytes} == {["MEMORY.md"], 65_536}

      for {settings, refusal} <- [
            {"{files: [], max_bytes: 10}",
             "context max_bytes is a number of bytes from 1024 to 262144"},
            {"{paths: [MEMORY.md]}",
             "context.paths is not a setting; expected files or max_bytes"},
            {"[../x.md]", "context: ../x.md climbs out of the workspace with .."}
          ] do
        assert {:error, message} =
                 read("---\ntools: [files]\ncontext: #{settings}\n---\n", context)

        assert message =~ refusal
      end
    end

    test "needs the file tools to read them with", context do
      assert {:error, message} = read("---\ncontext: [SOUL.md]\n---\n", context)
      assert message =~ "context names files to read into each turn, and tools names no files"
    end
  end
end
