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

  test "* is every shipped tool and every connected server", context do
    assert {:ok, spec} = read("---\ntools: ['*']\n---\n", context)

    assert spec.config.tools ==
             [TarsBrave.WebSearch, TarsResearch.Deep, TarsLua.Run, {TarsMCP, :*}]
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

  test "a policy that is not one is refused", context do
    assert {:error, message} = read("---\npolicy: TarsDaemon.AgentFileTest\n---\n", context)
    assert message =~ "TarsDaemon.AgentFileTest is not a policy"
  end

  test "frontmatter that is never closed, or is not YAML, says so", context do
    assert {:error, unclosed} = read("---\nmodel: x\n", context)
    assert unclosed =~ "never closed"

    assert {:error, yaml} = read("---\ntools: [a\n---\n", context)
    assert yaml =~ "not YAML"
  end
end
