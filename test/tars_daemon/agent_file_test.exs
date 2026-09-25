defmodule TarsDaemon.AgentFileTest do
  use ExUnit.Case, async: false

  alias Tars.Agent.Spec
  alias TarsDaemon.AgentFile

  @moduletag :tmp_dir

  defmodule Policy do
    @behaviour Tars.Policy

    @impl true
    def authorize(_call, _scope), do: :allow
  end

  setup do
    previous = Application.get_env(:tars, TarsMCP)

    Application.put_env(:tars, TarsMCP,
      servers: [linear: [transport: {:streamable_http, base_url: "https://mcp.linear.app/mcp"}]]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tars, TarsMCP, previous),
        else: Application.delete_env(:tars, TarsMCP)
    end)
  end

  defp read(name \\ "triage", text, context), do: read_with(name, text, context, %{})

  defp read_with(name, text, %{tmp_dir: dir}, policies) do
    path = Path.join(dir, "#{name}.md")
    File.write!(path, text)
    AgentFile.read(path, policies)
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
               policy: TarsDaemon.AgentFileTest.Policy
               ---
               You watch the incident queue.
               """,
               context
             )

    assert spec.name == "triage"
    assert Spec.key(spec) == "acme/jon/triage"
    assert spec.description == "Watches the queue."
    assert spec.config.model_spec == "anthropic:claude-sonnet-5"
    assert spec.config.system == "You watch the incident queue."
    assert spec.config.tools == [TarsBrave.WebSearch, {TarsMCP, :linear}]
    assert spec.config.max_iterations == 12
    assert spec.timeout == 600_000
    assert spec.policy == Policy
    assert spec.ledger == Tars.Ledger.Store
  end

  test "a file with no frontmatter is all prompt, and names no tools", context do
    assert {:ok, spec} = read("helper", "Answer briefly.\n", context)

    assert Spec.key(spec) == "_/_/helper"
    assert spec.config.system == "Answer briefly."
    assert spec.config.tools == []
    assert spec.policy == nil
  end

  test "name in the frontmatter wins over the file's", context do
    assert {:ok, spec} = read("file-name", "---\nname: triage\n---\nHi.\n", context)
    assert Spec.key(spec) == "_/_/triage"
  end

  test "* is every shipped tool, every connected server and the tool workers' tools", context do
    assert {:ok, spec} = read("---\ntools: ['*']\n---\n", context)

    assert spec.config.tools == [
             TarsBrave.WebSearch,
             TarsResearch.Deep,
             TarsLua.Run,
             {TarsMCP, :*},
             {TarsHTTP.Workers, "_/_/triage"}
           ]
  end

  test "workers/* is every tool the tool workers offer the agent, and * takes them too",
       context do
    assert {:ok, spec} = read("---\norg: acme\ntools: [workers/*]\n---\n", context)
    assert spec.config.tools == [{TarsHTTP.Workers, "acme/_/triage"}]

    assert {:ok, spec} = read("---\ntools: [\"*\"]\n---\n", context)
    assert {TarsHTTP.Workers, "_/_/triage"} in spec.config.tools

    assert {:error, message} = read("---\ntools: [workers/refund]\n---\n", context)

    assert message =~
             "name the workers' tools as workers/*, and let a policy deny what is not refund"
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

  test "one tool of a server is pointed at the server's only", context do
    assert {:error, message} = read("---\ntools: [linear/list_issues]\n---\n", context)
    assert message =~ "name the whole server as linear/*, and list list_issues in its only"
  end

  test "a key nothing takes is refused", context do
    assert {:error, message} = read("---\nmcp: [linear]\n---\n", context)
    assert message =~ "mcp is not a setting"
  end

  test "a named policy is the one policies/ holds, carried as a value", context do
    careful = TarsPolicy.decode!(%{"deny" => ["run_lua"]}, "careful")

    assert {:ok, spec} =
             read_with("triage", "---\npolicy: careful\n---\n", context, %{"careful" => careful})

    assert spec.policy == {TarsPolicy, careful}
  end

  test "a policy written in place is one too", context do
    assert {:ok, spec} = read("---\npolicy:\n  ask: [github/*]\n---\n", context)
    assert {TarsPolicy, %TarsPolicy{} = policy} = spec.policy
    assert {:ask, _prompt} = TarsPolicy.decide(policy, "github__create_issue")
  end

  test "a policy with a budget is the agent's dispatch as well", context do
    assert {:ok, spec} = read("---\npolicy:\n  budget:\n    usd: 5\n---\n", context)
    assert {TarsPolicy, %TarsPolicy{budget: %TarsPolicy.Budget{usd: 5.0}}} = spec.policy
    assert spec.dispatch == spec.policy

    assert {:ok, unbudgeted} = read("---\npolicy:\n  deny: [run_lua]\n---\n", context)
    assert unbudgeted.dispatch == nil
  end

  test "a policy written in place that does not read says why", context do
    assert {:error, message} = read("---\npolicy:\n  allows: [x]\n---\n", context)
    assert message =~ "policy allows is not a setting"
  end

  test "a policy name that is neither a policy nor a module is refused", context do
    assert {:error, message} = read("---\npolicy: careful\n---\n", context)
    assert message =~ "names careful, which is neither a policy in policies/ nor a module"
  end

  test "compaction is on by default, tuned or turned off by the file", context do
    assert {:ok, default} = read("---\n---\n", context)
    assert default.config.compaction == %Tars.Compaction{}

    assert {:ok, tuned} = read("---\ncompaction:\n  at: 0.5\n  window: 32000\n---\n", context)
    assert tuned.config.compaction == %Tars.Compaction{at: 0.5, keep: 0.25, window: 32_000}

    assert {:ok, off} = read("---\ncompaction: false\n---\n", context)
    assert off.config.compaction == nil

    assert {:error, message} = read("---\ncompaction:\n  at: 2\n---\n", context)
    assert message =~ "compaction at is a share of the window"

    assert {:error, message} = read("---\ncompaction:\n  at: 0.3\n  keep: 0.4\n---\n", context)
    assert message =~ ".md: a compaction keeps less than it waits for"
  end

  test "reads one schedule, or a list of them, into the spec", context do
    assert {:ok, one} =
             read(
               "---\nschedule:\n  every: \"*/30 * * * *\"\n  prompt: Check the queue.\n---\n",
               context
             )

    assert [%Tars.Schedule{name: "schedule-1", every: {:cron, "*/30 * * * *"}, overlap: :skip}] =
             one.schedules

    assert {:ok, two} =
             read(
               """
               ---
               schedule:
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
             %Tars.Schedule{name: "sweep", every: {:interval, 1_800_000}, jitter: 10_000},
             %Tars.Schedule{name: "digest", overlap: :queue, missed: :skip}
           ] = two.schedules

    assert {:ok, none} = read("---\n---\n", context)
    assert none.schedules == []
  end

  test "a schedule that does not read says which and why", context do
    assert {:error, message} =
             read("---\nschedule:\n  every: 10s\n  prompt: Look.\n---\n", context)

    assert message =~ "schedule 1: every: \"10s\" is shorter than a minute"

    assert {:error, message} =
             read("---\nschedule:\n  name: sweep\n  every: 30m\n---\n", context)

    assert message =~ "schedule sweep: prompt is a string"

    assert {:error, message} =
             read("---\nschedule:\n  every: 30m\n  prompt: Look.\n  when: now\n---\n", context)

    assert message =~ "schedule when is not a setting"

    assert {:error, message} =
             read(
               "---\nschedule:\n  every: 30m\n  prompt: Look.\n  overlap: interrupt\n---\n",
               context
             )

    assert message =~ "schedule 1: overlap is one of skip, queue"

    assert {:error, message} =
             read(
               "---\nschedule:\n  - {name: a, every: 30m, prompt: x}\n  - {name: a, every: 1h, prompt: y}\n---\n",
               context
             )

    assert message =~ "schedule names a twice"
  end

  describe "notify" do
    setup do
      previous = Application.get_env(:tars, TarsNotify)

      Application.put_env(
        :tars,
        TarsNotify,
        Keyword.put(previous, :targets,
          ops: {TarsNotify.Slack, channel: "#ops", token: "x"},
          audit: {TarsNotify.Webhook, url: "https://hooks.test"}
        )
      )

      on_exit(fn -> Application.put_env(:tars, TarsNotify, previous) end)
    end

    test "routes the agent's notices to the targets it names", %{tmp_dir: dir} = context do
      path = Path.join(dir, "triage.md")

      File.write!(path, "---\nnotify: ops\n---\n")

      assert {:ok, _spec, %TarsNotify.Route{targets: [:ops], on: [:parked, :failed]}} =
               AgentFile.load(path)

      File.write!(path, "---\nnotify: {to: [ops, audit], on: [finished]}\n---\n")

      assert {:ok, _spec, %TarsNotify.Route{targets: [:ops, :audit], on: [:finished]}} =
               AgentFile.load(path)

      File.write!(path, "---\n---\n")
      assert {:ok, _spec, nil} = AgentFile.load(path)

      assert {:ok, %Spec{}} = read("---\nnotify: ops\n---\n", context)
    end

    test "refuses a target config.yaml does not name, and a kind that is not one", context do
      assert {:error, message} = read("---\nnotify: pager\n---\n", context)

      assert message =~
               "notify names pager, but config.yaml's notify has no target pager; it has ops, audit"

      assert {:error, message} = read("---\nnotify: {to: ops, on: [started]}\n---\n", context)
      assert message =~ ~s(notify on lists "started")
    end
  end

  test "a policy that is not one is refused", context do
    assert {:error, message} = read("---\npolicy: TarsDaemon.AgentFileTest\n---\n", context)
    assert message =~ "TarsDaemon.AgentFileTest is not a policy"
  end

  describe "the definition schema" do
    defp schema do
      :tars
      |> Application.app_dir("priv/protocol/v1/agent_definition.json")
      |> File.read!()
      |> JSON.decode!()
    end

    # The keys a refusal says are expected.
    defp expected({:error, message}),
      do: message |> String.split("expected one of ") |> List.last() |> String.split(", ")

    test "lists the keys a definition takes, and a file takes them too, with its body as instructions",
         context do
      properties = Map.keys(schema()["properties"])

      assert Enum.sort(expected(AgentFile.definition("acme/_/triage", %{"?" => 1}))) ==
               Enum.sort(properties)

      assert Enum.sort(expected(read("---\n\"?\": 1\n---\n", context))) ==
               Enum.sort((properties -- ["instructions"]) ++ ~w(name org user schedule notify))
    end

    test "takes its example, which the reader reads" do
      schema = schema()
      root = JSV.build!(schema, resolver: Tars.Test.ProtocolResolver)

      for example <- schema["examples"] do
        assert {:ok, _} = JSV.validate(example, root)
        assert Enum.sort(Map.keys(example)) == Enum.sort(Map.keys(schema["properties"]))
        assert {:ok, %Spec{}} = AgentFile.definition("acme/_/triage", example)
      end
    end
  end

  describe "definition/3" do
    test "reads a definition into the spec of the agent under its key" do
      assert {:ok, spec} =
               AgentFile.definition("acme/_/triage", %{
                 "description" => "Watches the queue.",
                 "instructions" => "You watch the incident queue.",
                 "model" => "anthropic:claude-sonnet-5",
                 "tools" => ["web_search", "linear/*"],
                 "timeout" => 600
               })

      assert Spec.key(spec) == "acme/_/triage"
      assert {spec.org, spec.user, spec.name} == {"acme", nil, "triage"}
      assert spec.description == "Watches the queue."
      assert spec.config.system == "You watch the incident queue."
      assert spec.config.model_spec == "anthropic:claude-sonnet-5"
      assert spec.config.tools == [TarsBrave.WebSearch, {TarsMCP, :linear}]
      assert spec.timeout == :timer.seconds(600)
      assert spec.ledger == Tars.Ledger.Store
      assert spec.schedules == nil
    end

    test "an empty definition is an agent with no prompt and no tools" do
      assert {:ok, spec} = AgentFile.definition("_/_/blank", %{})

      assert spec.config.system == nil
      assert spec.config.tools == []
    end

    test "names a policy in policies/, or writes one in place" do
      careful = TarsPolicy.decode!(%{"deny" => ["run_lua"]}, "careful")

      assert {:ok, named} =
               AgentFile.definition("acme/_/triage", %{"policy" => "careful"}, %{
                 "careful" => careful
               })

      assert named.policy == {TarsPolicy, careful}

      assert {:ok, written} =
               AgentFile.definition("acme/_/triage", %{"policy" => %{"ask" => ["github/*"]}})

      assert {TarsPolicy, %TarsPolicy{}} = written.policy
    end

    test "never names a module" do
      assert {:error, message} =
               AgentFile.definition("acme/_/triage", %{"tools" => ["TarsLua.Run"]})

      assert message == "tools names TarsLua.Run, which is not a tool the daemon ships"

      assert {:error, message} =
               AgentFile.definition("acme/_/triage", %{
                 "policy" => "TarsDaemon.AgentFileTest.Policy"
               })

      assert message ==
               "policy names TarsDaemon.AgentFileTest.Policy, which is not a policy in policies/"
    end

    test "takes who the agent is from its key, and its schedules from their own routes" do
      for key <- ~w(name org user schedule notify) do
        assert {:error, message} = AgentFile.definition("acme/_/triage", %{key => "x"})
        assert message =~ "#{key} is not a setting; expected one of description, instructions"
      end
    end

    test "a definition that does not read says why" do
      assert {:error, "timeout is a whole number of seconds"} =
               AgentFile.definition("acme/_/triage", %{"timeout" => "soon"})

      assert {:error, "instructions is a string"} =
               AgentFile.definition("acme/_/triage", %{"instructions" => ["a"]})
    end
  end

  test "frontmatter that is never closed, or is not YAML, says so", context do
    assert {:error, unclosed} = read("---\nmodel: x\n", context)
    assert unclosed =~ "never closed"

    assert {:error, yaml} = read("---\ntools: [a\n---\n", context)
    assert yaml =~ "not YAML"
  end
end
