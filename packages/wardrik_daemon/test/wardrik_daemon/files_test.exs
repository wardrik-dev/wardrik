defmodule WardrikDaemon.FilesTest do
  use ExUnit.Case, async: true

  import WardrikDaemon.Test

  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.Config
  alias WardrikDaemon.EnvFile
  alias WardrikDaemon.Policies

  setup context, do: dirs(context)

  @config %Config{
    org: "acme",
    orgs: %{"growth" => %{}},
    defaults: %{"model" => "anthropic:claude-haiku-4-5", "timeout" => 60}
  }

  test "reads an agent's file into its name and definition, over the defaults", context do
    path =
      write(context, "agents/triage.md", """
      ---
      description: Triages.
      timeout: 120
      ---
      You watch the queue.
      """)

    assert AgentFile.read(path, @config) ==
             {:ok, %{org: "acme", owner: "acme", name: "triage"},
              %{
                "description" => "Triages.",
                "model" => "anthropic:claude-haiku-4-5",
                "timeout" => 120,
                "instructions" => "You watch the queue."
              }}
  end

  test "names the agent by its file, in its org, for its owner", context do
    plain = write(context, "agents/plain.md", "Be brief.")

    assert {:ok, %{org: "acme", owner: "acme", name: "plain"}, %{"instructions" => "Be brief."}} =
             AgentFile.read(plain, @config)

    for {front, org, owner} <- [
          {~s(owner: "@jon"), "acme", "acme/@jon"},
          {"owner: acme/@jon", "acme", "acme/@jon"},
          {"org: growth", "growth", "growth"},
          {"owner: growth/@ana", "growth", "growth/@ana"},
          {~s(org: growth\nowner: "@ana"), "growth", "growth/@ana"}
        ] do
      path = write(context, "agents/notes.md", "---\n#{front}\n---\n")
      assert {:ok, agent, definition} = AgentFile.read(path, @config)
      assert agent == %{org: org, owner: owner, name: "notes"}
      assert definition == %{"model" => "anthropic:claude-haiku-4-5", "timeout" => 60}
    end
  end

  test "says why a file doesn't read", context do
    refused = [
      {"---\norg: globex\n---\n", "is in the org \"globex\""},
      {"---\norg: growth\nowner: acme/@jon\n---\n", "is owned by"},
      {"---\nowner: deployment\n---\n", "is in the org \"deployment\""},
      {"---\nowner: 42\n---\n", "is owned by"},
      {"---\nname: notes\n---\n", "the file's name is its name"},
      {"---\nuser: jon\n---\n", "the file's name is its name"},
      {"---\nmodel: x\n", "never closes it"},
      {"---\n- a\n---\n", "isn't a set of keys"},
      {"---\na: [\n---\n", "isn't YAML"}
    ]

    for {text, why} <- refused do
      path = write(context, "agents/bad.md", text)
      assert {:error, message} = AgentFile.read(path, @config)
      assert message =~ why
    end

    none = Path.join(context.root, "none.md")
    assert {:error, message} = AgentFile.read(none, @config)
    assert message =~ "no such file"

    path = write(context, "agents/a b.md", "Be brief.")
    assert {:error, message} = AgentFile.read(path, @config)
    assert message =~ "isn't named as an agent is"
  end

  test "reads each policy by its file's name", context do
    write(context, "policies/careful.yaml", "ask: [echo]\n")
    write(context, "policies/open.yml", "default: allow\n")

    policies = Path.join(context.env["WARDRIK_CONFIG_DIR"], "policies")

    assert {:ok, %{"careful" => %Wardrik.Policy{}, "open" => %Wardrik.Policy{}}} =
             Policies.read(policies)

    empty = write(context, "policies/empty.yaml", "")

    assert {:error, message} = Policies.read(policies)
    assert message =~ "empty.yaml: is empty"

    File.rm!(empty)
    odd = write(context, "policies/odd.yaml", "colour: red\n")

    assert {:error, _why} = Policies.read(policies)

    File.rm!(odd)
    write(context, "policies/broken.yaml", "a: [\n")

    assert {:error, message} = Policies.read(policies)
    assert message =~ "isn't YAML"
  end

  test "sets what the env file says where the environment doesn't", context do
    path =
      write(context, "env", """
      # keys
      export ANTHROPIC_API_KEY="sk-ant"
      SLACK_BOT_TOKEN='xoxb'
      HOME=/elsewhere
      not a variable
      9BAD=1
      """)

    assert EnvFile.load(path, %{"HOME" => "/home/me"}) == %{
             "ANTHROPIC_API_KEY" => "sk-ant",
             "SLACK_BOT_TOKEN" => "xoxb",
             "HOME" => "/home/me"
           }

    none = Path.join(context.root, "none")
    assert EnvFile.load(none, %{"A" => "1"}) == %{"A" => "1"}
  end
end
