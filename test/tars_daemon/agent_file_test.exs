defmodule TarsDaemon.AgentFileTest do
  use ExUnit.Case, async: false

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

  defp read(name \\ "triage", text, %{tmp_dir: dir}) do
    path = Path.join(dir, "#{name}.md")
    File.write!(path, text)
    AgentFile.read(path)
  end

  test "reads a whole file into an agent's key and spawn options", context do
    assert {:ok, file} =
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

    assert file.name == "triage"
    assert file.key == "acme/jon/triage"
    assert file.description == "Watches the queue."

    config = file.opts[:config]
    assert config.model_spec == "anthropic:claude-sonnet-5"
    assert config.system == "You watch the incident queue."
    assert config.tools == [TarsBrave.WebSearch, {TarsMCP, :linear}]
    assert config.max_iterations == 12
    assert file.opts[:timeout] == 600_000
    assert file.opts[:policy] == Policy
  end

  test "a file with no frontmatter is all prompt, and names no tools", context do
    assert {:ok, file} = read("helper", "Answer briefly.\n", context)

    assert file.key == "_/_/helper"
    assert file.opts[:config].system == "Answer briefly."
    assert file.opts[:config].tools == []
  end

  test "name in the frontmatter wins over the file's", context do
    assert {:ok, file} = read("file-name", "---\nname: triage\n---\nHi.\n", context)
    assert file.key == "_/_/triage"
  end

  test "* is every shipped tool and every connected server", context do
    assert {:ok, file} = read("---\ntools: ['*']\n---\n", context)

    assert file.opts[:config].tools ==
             [TarsBrave.WebSearch, TarsResearch.Deep, TarsLua.Run, {TarsMCP, :*}]
  end

  test "a tool nothing ships is refused", context do
    assert {:error, message} = read("---\ntools: [websearch]\n---\n", context)
    assert message =~ "triage.md: names websearch, which is neither a module nor a tool"
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
