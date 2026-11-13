defmodule WardrikDaemon.SetupTest do
  use ExUnit.Case, async: true

  import WardrikDaemon.Test

  alias WardrikDaemon.CLI.Answers
  alias WardrikDaemon.Dirs
  alias WardrikDaemon.Setup
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

  defp installed(context, name) do
    path = Path.join(context.bin, name)
    File.write!(path, "#!/bin/sh\n")
    File.chmod!(path, 0o755)
    path
  end

  defp machine(context), do: Machine.new(context.env, Dirs.new(context.env))
  defp yes(_question), do: {:ok, true}
  defp config(context, name), do: File.read!(Path.join(context.env["WARDRIK_CONFIG_DIR"], name))

  test "finds executables on the environment's PATH alone", context do
    File.write!(Path.join(context.bin, "plain"), "")
    installed = installed(context, "claude")

    assert Machine.executable(machine(context), "claude") == installed
    assert Machine.executable(machine(context), "plain") == nil

    assert Machine.executable(
             machine(%{context | env: Map.delete(context.env, "PATH")}),
             "claude"
           ) == nil
  end

  test "offers nothing without Claude Code, or with a claude harness already", context do
    assert {:ok, [], []} = Setup.plan([ClaudeCode], machine(context), &yes/1)

    installed(context, "claude")
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
    {:ok, read} = YamlElixir.read_from_string(config(context, "config.yaml"))
    assert Map.keys(read["harnesses"]) == ["claude", "codex"]
    assert read["http"] == %{"port" => 1}

    write(context, "config.yaml", "harnesses: {}\n")

    assert {:error, message} = Setup.apply(entry, Dirs.new(context.env))
    assert message =~ "writes harnesses on one line. Add this under it by hand:\n\n  claude:\n"
  end

  test "adds the claude harness and the coding policy, and shows how to install the adapter",
       context do
    installed(context, "claude")

    assert {:ok, changes, ["coding.claude"]} = Setup.plan([ClaudeCode], machine(context), &yes/1)

    assert {:ok,
            [
              {:wrote, _config},
              {:wrote, _policy},
              {:command, "npm install -g @agentclientprotocol/claude-agent-acp", _why}
            ]} = Setup.apply(changes, Dirs.new(context.env))

    {:ok, read} = YamlElixir.read_from_string(config(context, "config.yaml"))
    assert read["org"] == "acme"

    assert %{"command" => "claude-agent-acp", "env" => env, "options" => %{"mode" => "default"}} =
             read["harnesses"]["claude"]

    assert env == %{"PATH" => context.env["PATH"]}
    assert {:ok, [{"claude", _harness}]} = WardrikDaemon.Config.Harnesses.read(read["harnesses"])

    assert {:ok, %{"coding" => _policy}} =
             WardrikDaemon.Policies.read(Path.join(context.env["WARDRIK_CONFIG_DIR"], "policies"))

    assert {:ok, [{:kept, _config}, {:kept, _policy}, {:command, _command, _why}]} =
             Setup.apply(changes, Dirs.new(context.env))
  end

  test "runs the adapter it finds, and passes a key when Claude Code isn't signed in", context do
    adapter = installed(context, "claude-agent-acp")
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")

    {:ok, changes, _asked} = Setup.plan([ClaudeCode], machine(context), &yes/1)

    assert {:ok, [{:wrote, _config}, {:wrote, _policy}]} =
             Setup.apply(changes, Dirs.new(context.env))

    assert config(context, "config.yaml") =~ "command: #{adapter}\n"
    assert config(context, "config.yaml") =~ "ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}"

    File.mkdir_p!(Path.join(context.root, ".claude"))
    File.write!(Path.join(context.root, ".claude/.credentials.json"), "{}")
    write(context, "config.yaml", "org: acme\n")

    {:ok, changes, _asked} = Setup.plan([ClaudeCode], machine(context), &yes/1)
    {:ok, _done} = Setup.apply(changes, Dirs.new(context.env))
    refute config(context, "config.yaml") =~ "ANTHROPIC_API_KEY"
  end

  test "changes nothing when the answer is no, and stops at an answer that fails", context do
    installed(context, "claude")

    assert {:ok, [], ["coding.claude"]} =
             Setup.plan([ClaudeCode], machine(context), fn _question -> {:ok, false} end)

    assert {:error, "no"} =
             Setup.plan([ClaudeCode], machine(context), fn _question -> {:error, "no"} end)
  end

  test "reads answers from --set and --answers, the set ones first", context do
    file = Path.join(context.root, "answers.yaml")
    File.write!(file, "coding:\n  claude: true\nother: 1\n")

    assert {:ok, %{"coding.claude" => true, "other" => 1}} = Answers.given(%{answers: file})

    assert {:ok, %{"coding.claude" => "no"}} =
             only(Answers.given(%{answers: file, set: ["coding.claude=no"]}), "coding.claude")

    assert {:error, "--set coding: is KEY=VALUE" <> _} = Answers.given(%{set: ["coding"]})

    assert {:error, "--answers " <> _} =
             Answers.given(%{answers: Path.join(context.root, "none")})

    assert Answers.unasked(%{"coding.claude" => true, "codng.claude" => true}, ["coding.claude"]) ==
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
end
