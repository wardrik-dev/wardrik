defmodule WardrikDaemon.SetupTest do
  use ExUnit.Case, async: true

  import WardrikDaemon.Test

  alias WardrikDaemon.CLI.Answers
  alias WardrikDaemon.Dirs
  alias WardrikDaemon.Setup
  alias WardrikDaemon.Setup.Approvals
  alias WardrikDaemon.Setup.Choice
  alias WardrikDaemon.Setup.ClaudeCode
  alias WardrikDaemon.Setup.Machine
  alias WardrikDaemon.Setup.Question

  setup context do
    context = dirs(context)
    bin = Path.join(context.root, "bin")
    File.mkdir_p!(bin)
    write(context, "config.yaml", "org: acme\n")

    Map.merge(context, %{bin: bin, env: Map.put(context.env, "PATH", "/nowhere:" <> bin)})
  end

  defp install(context, name) do
    path = Path.join(context.bin, name)
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o755)
    path
  end

  defp machine(context), do: Machine.new(context.env, Dirs.new(context.env))
  defp yes(_question), do: {:ok, true}

  defp config(context, name) do
    path = Path.join(context.env["WARDRIK_CONFIG_DIR"], name)
    File.read!(path)
  end

  test "finds executables on the environment's PATH alone", context do
    plain = Path.join(context.bin, "plain")
    File.write!(plain, "")
    installed = install(context, "claude")
    machine = machine(context)
    pathless = machine(%{context | env: Map.delete(context.env, "PATH")})

    assert Machine.executable(machine, "claude") == installed
    assert Machine.executable(machine, "plain") == nil
    assert Machine.executable(pathless, "claude") == nil
  end

  test "offers nothing without Claude Code, or with a claude harness already", context do
    assert {:ok, [], []} = Setup.plan([ClaudeCode], machine(context), &yes/1)

    install(context, "claude")
    write(context, "config.yaml", "harnesses: {claude: {command: claude-agent-acp}}\n")
    assert {:ok, [], []} = Setup.plan([ClaudeCode], machine(context), &yes/1)
  end

  test "adds an entry under a section that's there, and says how where it can't", context do
    write(
      context,
      "config.yaml",
      "org: acme\nharnesses: # coding\n  codex:\n    command: codex-acp\nhttp: {port: 1}\n"
    )

    entry = [{:entry, "config.yaml", "harnesses", "claude", "command: claude-agent-acp\n"}]

    assert {:ok, [{:wrote, _path}]} = Setup.apply(entry, Dirs.new(context.env))

    {:ok, read} =
      context
      |> config("config.yaml")
      |> YamlElixir.read_from_string()

    assert Map.keys(read["harnesses"]) == ["claude", "codex"]
    assert read["http"] == %{"port" => 1}

    write(context, "config.yaml", "harnesses: {}\n")

    assert {:error, message} = Setup.apply(entry, Dirs.new(context.env))
    assert message =~ "writes harnesses on one line. Add this under it by hand:\n\n  claude:\n"
  end

  test "adds the claude harness and the coding policy, and shows how to install the adapter",
       context do
    install(context, "claude")

    assert {:ok, changes, ["coding.claude"]} = Setup.plan([ClaudeCode], machine(context), &yes/1)

    assert {:ok,
            [
              {:wrote, _config},
              {:wrote, _policy},
              {:command, "npm install -g @agentclientprotocol/claude-agent-acp", _why}
            ]} = Setup.apply(changes, Dirs.new(context.env))

    {:ok, read} =
      context
      |> config("config.yaml")
      |> YamlElixir.read_from_string()

    assert read["org"] == "acme"

    assert %{"command" => "claude-agent-acp", "env" => env, "options" => %{"mode" => "default"}} =
             read["harnesses"]["claude"]

    assert env == %{"PATH" => context.env["PATH"]}
    assert {:ok, [{"claude", _harness}]} = WardrikDaemon.Config.Harnesses.read(read["harnesses"])

    policies = Path.join(context.env["WARDRIK_CONFIG_DIR"], "policies")
    assert {:ok, %{"coding" => _policy}} = WardrikDaemon.Policies.read(policies)

    assert {:ok, [{:kept, _config}, {:kept, _policy}, {:command, _command, _why}]} =
             Setup.apply(changes, Dirs.new(context.env))
  end

  test "runs the adapter it finds, and passes a key when Claude Code isn't signed in", context do
    adapter = install(context, "claude-agent-acp")
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")

    {:ok, changes, _asked} = Setup.plan([ClaudeCode], machine(context), &yes/1)

    assert {:ok, [{:wrote, _config}, {:wrote, _policy}]} =
             Setup.apply(changes, Dirs.new(context.env))

    assert config(context, "config.yaml") =~ "command: #{adapter}\n"
    assert config(context, "config.yaml") =~ "ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}"

    claude = Path.join(context.root, ".claude")
    credentials = Path.join(claude, ".credentials.json")
    File.mkdir_p!(claude)
    File.write!(credentials, "{}")
    write(context, "config.yaml", "org: acme\n")

    {:ok, changes, _asked} = Setup.plan([ClaudeCode], machine(context), &yes/1)
    {:ok, _done} = Setup.apply(changes, Dirs.new(context.env))
    refute config(context, "config.yaml") =~ "ANTHROPIC_API_KEY"
  end

  test "changes nothing when the answer is no, and stops at an answer that fails", context do
    install(context, "claude")

    assert {:ok, [], ["coding.claude"]} =
             Setup.plan([ClaudeCode], machine(context), fn _question -> {:ok, false} end)

    assert {:error, "no"} =
             Setup.plan([ClaudeCode], machine(context), fn _question -> {:error, "no"} end)
  end

  test "reads answers from --set and --answers, the set ones first", context do
    file = Path.join(context.root, "answers.yaml")
    File.write!(file, "coding:\n  claude: true\nother: 1\n")

    assert {:ok, %{"coding.claude" => true, "other" => 1}} = Answers.parse_given(%{answers: file})

    assert {:ok, %{"coding.claude" => "no"}} =
             only(
               Answers.parse_given(%{answers: file, set: ["coding.claude=no"]}),
               "coding.claude"
             )

    assert {:error, "--set coding: is KEY=VALUE" <> _} = Answers.parse_given(%{set: ["coding"]})

    assert {:error, "--answers " <> _} =
             Answers.parse_given(%{answers: Path.join(context.root, "none")})

    assert Answers.list_unasked(%{"coding.claude" => true, "codng.claude" => true}, [
             "coding.claude"
           ]) ==
             ["Nothing asked codng.claude: no step here offers it."]
  end

  defp only({:ok, given}, key), do: {:ok, Map.take(given, [key])}

  test "casts yes and no", _context do
    question = %Question{key: "coding.claude", label: "Use it?"}

    assert Question.cast(question, "yes") == {:ok, true}
    assert Question.cast(question, "FALSE") == {:ok, false}
    assert Question.cast(question, true) == {:ok, true}

    assert Question.cast(question, "maybe") ==
             {:error, ~s(coding.claude is true or false, not "maybe".)}
  end

  test "casts a choice's answers, and answers one unattended with its default", context do
    choice = Approvals.question()

    assert Choice.cast(choice, "careful") == {:ok, "careful"}

    assert Choice.cast(choice, "reckless") ==
             {:error, ~s(approvals is one of balanced, careful, hands-off, not "reckless".)}

    cx = WardrikDaemon.CLI.Context.new(context.env)
    assert Answers.answer(cx, %{}, %{yes: true}).(choice) == {:ok, "balanced"}
    assert Answers.answer(cx, %{"approvals" => "hands-off"}, %{}).(choice) == {:ok, "hands-off"}
  end

  test "writes approvals' policies the daemon reads, each refusing deletes", context do
    dir = Path.join(context.root, "policies")
    File.mkdir_p!(dir)

    for {name, _label} <- Approvals.question().options do
      {path, text} = Approvals.policy_file(name)
      file = Path.join(context.root, path)
      File.write!(file, text)
    end

    assert {:ok, %{"balanced" => balanced, "careful" => _careful, "hands-off" => hands_off}} =
             WardrikDaemon.Policies.read(dir)

    assert Wardrik.Policy.decide(balanced, "agent_create") == :allow
    assert {:deny, _why} = Wardrik.Policy.decide(balanced, "mail__GMAIL_DELETE_MESSAGE")
    assert Wardrik.Policy.decide(hands_off, "mail__GMAIL_SEND_EMAIL") == :allow
    assert {:deny, _why} = Wardrik.Policy.decide(hands_off, "files__delete_file")
  end
end
