defmodule Wardrik.Definition.ReadingTest do
  use ExUnit.Case, async: true

  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.LLM.Retry.Backoff
  alias Wardrik.Resource
  alias WardrikDefinition.Context
  alias WardrikDefinition.Test.Served

  import Wardrik.AgentID, only: [sigil_A: 2]

  defmodule Hook do
    use Wardrik.Hook

    @impl true
    def init(_opts), do: nil

    @impl true
    def call(_call, _value), do: :pass
  end

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

  defmodule Lua do
    use Wardrik.Tool

    @impl Wardrik.Tool
    def tool,
      do:
        Wardrik.Tool.new!(
          name: "run_lua",
          description: "Runs Lua.",
          run: fn input, _context -> {:ok, input} end
        )
  end

  defmodule Source do
    use Wardrik.Tool

    @impl Wardrik.Tool
    def tools(_argument), do: []
  end

  setup do
    %{
      context: %Context{
        names: %{host: "the daemon", config: "config.yaml", policies: "policies/"}
      }
    }
  end

  # The definition an agent file `text` named `name` writes, as an operator's file.
  defp definition(name, text, %{context: context}) do
    with {:ok, id, fields} <- Definition.parse(text, name, context),
         do:
           Definition.read(fields, id: id, source: {:file, "agents/#{name}.md"}, context: context)
  end

  # The spec an agent file `text` named `name` writes.
  # The host the definitions are read on: its tools, and its sources as `name/*`.
  defp host do
    Wardrik.Host.new()
    |> Wardrik.Host.register(:tools, [{"web_search", Search}, {"run_lua", Lua}])
    |> Wardrik.Host.register(:sources, [
      {"workers", Source},
      {"self", Wardrik.Catalog.Self},
      {"agents", Wardrik.Catalog.Agents},
      {"linear", %Served{name: "linear", source: Source}},
      {"theirs", %Served{name: "theirs", source: Source, serves: [Resource.parse!("globex/*")]}}
    ])
  end

  defp built(definition, context),
    do: Definition.spec(definition, context: context, host: host())

  defp read(name \\ "triage", text, %{context: context} = test) do
    with {:ok, definition} <- definition(name, text, test),
         do: built(definition, context)
  end

  defp with_policies(%{context: context}, policies),
    do: %{context: %{context | policies: policies}}

  # The spec a definition sent to the HTTP API writes for `id`, sent by no token.
  defp define(id, fields, %{context: context}) do
    with {:ok, definition} <- Definition.read(fields, id: id, source: :defaults, context: context),
         do: built(definition, context)
  end

  # Where the notices of the agent a file `text` declares go, once the file reads.
  defp route(text, test) do
    with {:ok, definition} <- definition("triage", text, test),
         do: definition.notify
  end

  defp triggers(text, test) do
    with {:ok, definition} <- definition("triage", text, test),
         do: {:ok, definition.triggers}
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

    assert spec.id == ~A"acme/@jon/triage"
    assert spec.description == "Watches the queue."
    assert spec.config.model_spec == "anthropic:claude-sonnet-5"
    assert spec.config.system == "You watch the incident queue."
    assert spec.config.tools == [Search, {Source, Resource.parse!("deployment/server/linear")}]
    assert spec.config.max_iterations == 12
    assert spec.timeout == 600_000
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

  test "retries are how often and how long a failed model call is tried again", context do
    assert {:ok, %{retry: %Backoff{attempts: 6, max_wait: 60_000, on_exhausted: :ask}}} =
             read("Answer briefly.\n", context)

    written = "---\nretries: {attempts: 2, max_wait: 30, on_exhausted: fail}\n---\n"

    assert {:ok, %{retry: %Backoff{attempts: 2, max_wait: 30_000, on_exhausted: :fail}}} =
             read(written, context)

    assert {:ok, %{retry: %Backoff{attempts: 0, max_wait: 60_000}}} =
             read("---\nretries: {attempts: 0}\n---\n", context)

    for {written, message} <- [
          {"[1, 5]", "retries is a set of attempts, max_wait and on_exhausted"},
          {"{attempts: -1}", "retries.attempts is a whole number of tries after the first"},
          {"{max_wait: 1.5}", "retries.max_wait is a whole number of seconds"},
          {"{on_exhausted: retry}", "retries.on_exhausted is ask or fail"},
          {"{waits: [1]}",
           "retries.waits is not a setting; expected attempts, max_wait or on_exhausted"}
        ] do
      assert {:error, ^message} = read("---\nretries: #{written}\n---\n", context)
    end

    defaults = %{context: %{context.context | defaults: %{"retries" => %{"attempts" => 3}}}}
    assert {:ok, %{retry: %Backoff{attempts: 3}}} = read("Answer briefly.\n", defaults)

    assert {:ok, %{retry: %Backoff{attempts: 1, on_exhausted: :ask}}} =
             read("---\nretries: {attempts: 1}\n---\n", defaults)
  end

  test "text/1 writes a file that reads back as it was given", context do
    text =
      Definition.text([
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
      Definition.text(
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
             Lua,
             Search,
             {Wardrik.Catalog.Agents, ~A"default/triage"},
             {Source, Resource.parse!("deployment/server/linear")},
             {Wardrik.Catalog.Self, ~A"default/triage"},
             {Source, ~A"default/triage"},
             {WardrikWorkspace, files}
           ]

    assert {:ok, spec} = read("---\ntools: ['*']\norg: globex\n---\n", context)
    assert {Source, Resource.parse!("deployment/server/theirs")} in spec.config.tools
  end

  test "a server is refused to an agent of an org it does not serve", context do
    assert {:error, "tools names theirs/*, but theirs serves globex/*, and not default/triage"} =
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
      assert files.tree.tree == "agents/acme/agent/triage"

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
               "workspace shared theirs: globex belongs to globex/agent/*, which does not cover " <>
                 "acme/triage"
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

      assert {files.tree.tree, team.tree} == {"agents/acme/agent/triage", "shared/acme"}
      assert files.context == ["shared/team/NOTES.md"]

      token = Wardrik.Token.root(Wardrik.Principal.new("acme/@jon"))
      token = %{token | scope: [Wardrik.Role.bind([:owner], [Wardrik.AgentID.resource(id)])]}

      {:ok, definition} = Definition.read(fields, id: id, source: {:api, token}, context: context)

      assert built(definition, context) ==
               {:error,
                "workspace shared team: acme belongs to acme/agent/*, which the token does not reach"}
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
    assert {:error, "tools names websearch, which is not a tool the daemon ships"} =
             read("---\ntools: [websearch]\n---\n", context)

    assert {:error,
            "tools names github/*, but the daemon has no github/*; it has agents/*, linear/*, " <>
              "self/*, theirs/*, workers/*"} = read("---\ntools: [github/*]\n---\n", context)

    assert {:error, "tools names Wardrik.Definition.ReadingTest.Lua, which is not a tool " <> _} =
             read("---\ntools: [Wardrik.Definition.ReadingTest.Lua]\n---\n", context)

    assert {:error, message} = read("---\ntools: [linear/list_issues]\n---\n", context)
    assert message =~ "name the source's tools as linear/*, and let a policy deny"

    assert {:error, message} = read("---\ntools: [github/list_issues]\n---\n", context)
    assert message =~ "name the whole server as github/*, and list list_issues in its only"

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

  test "a policy is one policies/ names, or rules written in place", context do
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

    assert {:error, "policy names careful, which is not a policy in policies/"} =
             read("---\npolicy: careful\n---\n", context)

    assert {:error,
            "policy names Wardrik.Definition.ReadingTest.Hook, which is not a policy in policies/"} =
             read("---\npolicy: Wardrik.Definition.ReadingTest.Hook\n---\n", context)

    assert {:error, "policy is the name of a policy, or rules"} =
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
    assert default.config.history == %Wardrik.Compaction{}

    assert {:ok, tuned} = read("---\ncompaction:\n  at: 0.5\n  window: 32000\n---\n", context)

    assert tuned.config.history == %Wardrik.Compaction{at: 0.5, keep: 0.25, window: 32_000}

    assert {:ok, %{config: %{history: %Wardrik.History.All{}}}} =
             read("---\ncompaction: false\n---\n", context)

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

  test "channels are names, each offering the agent where it serves its org", context do
    assert {:ok, definition} =
             definition("triage", "---\nchannels: [slack, teams]\n---\n", context)

    assert definition.channels == ["slack", "teams"]
    assert {:ok, %{channels: []}} = definition("triage", "", context)

    assert {:error, "channels is a list of the channels it is offered in"} =
             read("---\nchannels: slack\n---\n", context)

    assert {:error, "channels is a list of the channels it is offered in"} =
             read("---\nchannels: [1]\n---\n", context)
  end

  test "notify routes the agent's notices to targets by name, and to rooms in channels",
       context do
    assert %WardrikDefinition.Route{targets: ["ops"], on: [:parked, :failed]} =
             route("---\nnotify: ops\n---\n", context)

    assert %WardrikDefinition.Route{targets: ["ops", "audit"], on: [:finished]} =
             route("---\nnotify: {to: [ops, audit], on: [finished]}\n---\n", context)

    assert %WardrikDefinition.Route{targets: ["ops"], rooms: [room]} =
             route(~s(---\nnotify: ["slack:#updates", ops]\n---\n), context)

    assert room == %WardrikDefinition.Room{channel: "slack", room: "#updates"}
    assert to_string(room) == "slack:#updates"
    assert nil == route("---\n---\n", context)

    for {settings, refusal} <- [
          {"{to: ops, on: [started]}", ~s(notify on lists "started")},
          {"{to: []}", "notify names no target"},
          {"{to: ops, when: now}", "notify when is not a setting; expected to or on"},
          {"[1]", "notify names 1, which is not a target"},
          {~s(":#ops"), ~s(notify names ":#ops"; a room is its channel, : and the room)},
          {~s("slack:"), ~s(notify names "slack:"; a room is its channel)},
          {"5", "notify is a target, a list of them, or to and on"}
        ] do
      assert {:error, message} = route("---\nnotify: #{settings}\n---\n", context)
      assert message =~ refusal
    end
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
      assert spec.config.tools == [Search, {Source, Resource.parse!("deployment/server/linear")}]
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

        assert message =~
                 "#{key} is not a setting; expected one of display_name, description, instructions"
      end

      assert {:error, "timeout is a whole number of seconds"} =
               define(~A"acme/triage", %{"timeout" => "soon"}, context)

      assert {:error, "instructions is a string"} =
               define(~A"acme/triage", %{"instructions" => ["a"]}, context)
    end

    test "lists its triggers as a file does, and one is set or deleted in it" do
      unnamed = %{"every" => "1h", "prompt" => "Look."}
      context = %Context{}

      {:ok, definition} =
        Definition.read(
          %{"triggers" => [unnamed, %{"every" => "1d", "prompt" => "Sum up."}]},
          id: ~A"acme/triage",
          source: :defaults,
          context: context
        )

      assert [%WardrikTrigger{name: "trigger-1"}, %WardrikTrigger{name: "trigger-2"}] =
               definition.triggers

      assert {:ok, definition, :changed,
              %WardrikTrigger{every: %WardrikTrigger.Interval{ms: 7_200_000}}} =
               Definition.put_trigger(
                 definition,
                 "trigger-1",
                 %{unnamed | "every" => "2h"},
                 context
               )

      assert {:ok, definition, :created, %WardrikTrigger{name: "sweep"}} =
               Definition.put_trigger(definition, "sweep", unnamed, context)

      assert ~w(trigger-1 trigger-2 sweep) == Enum.map(definition.triggers, & &1.name)

      assert {:error, "trigger sweep: prompt is a string" <> _rest} =
               Definition.put_trigger(definition, "sweep", %{"every" => "1h"}, context)

      {:ok, definition, _trigger} = Definition.delete_trigger(definition, "trigger-2", context)
      {:ok, definition, _trigger} = Definition.delete_trigger(definition, "trigger-1", context)
      assert {:error, :not_found} = Definition.delete_trigger(definition, "trigger-1", context)
      {:ok, definition, _trigger} = Definition.delete_trigger(definition, "sweep", context)
      assert definition.fields == %{}

      assert %{"triggers" => [%{"every" => "1h"}], "notify" => "ops"} =
               Definition.written_fields(%{"triggers" => unnamed, "notify" => "ops"})
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
