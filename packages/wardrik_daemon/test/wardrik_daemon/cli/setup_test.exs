defmodule WardrikDaemon.CLI.SetupTest do
  use WardrikDaemon.CLICase, async: true

  test "writes a first config and agent, keeps what's there, and starts the daemon", context do
    {context, log} = script(context)
    config = Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")
    File.rm!(config)
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")

    assert {0, output} = wardrik(context, init() ++ ~w(--org globex --model claude-sonnet-5))
    assert output =~ "ANTHROPIC_API_KEY is read from " <> context.env["WARDRIK_CONFIG_DIR"]
    assert output =~ "Wrote " <> config
    assert output =~ "agents/assistant.md"
    assert output =~ "Kept  " <> Path.join(context.env["WARDRIK_CONFIG_DIR"], "env")
    assert output =~ ~s(wardrik ask assistant "Tell me when)
    assert File.read!(log) == "start\n"

    assert File.read!(config) =~
             "org: globex\n\ndefaults:\n  model: anthropic:claude-sonnet-5\n"

    assert {0, again} = wardrik(context, init() ++ ~w(--no-service))
    assert again =~ "Kept"
    refute again =~ "names no default model"

    write(context, "config.yaml", "org: globex\n")
    assert {0, again} = wardrik(context, init() ++ ~w(--no-service))
    assert again =~ "config.yaml names no default model, so the assistant has none. Add it:"
    assert File.read!(log) == "start\nstart\nstart\n"
  end

  test "offers Claude Code where it finds it, and takes the answer without a terminal", context do
    {context, _log} = script(context)
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")
    bin = Path.join(context.root, "bin")
    File.mkdir_p!(bin)
    claude = Path.join(bin, "claude")
    File.write!(claude, "#!/bin/sh\n")
    File.chmod!(claude, 0o755)
    context = put_in(context.env["PATH"], bin)
    config = Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")

    assert {0, output} = wardrik(context, init() ++ ~w(--no-service --set codng.claude=yes))
    assert output =~ "Nothing asked codng.claude"
    refute File.read!(config) =~ "harnesses"

    assert {0, output} = wardrik(context, init() ++ ~w(--no-service --set coding.claude=yes))
    assert output =~ "Wrote " <> config
    assert output =~ "policies/coding.yaml"
    assert output =~ "npm install -g @agentclientprotocol/claude-agent-acp"

    assert {:ok, %{"harnesses" => %{"claude" => %{"command" => "claude-agent-acp"}}}} =
             YamlElixir.read_from_file(config)

    assert failing(context, init() ++ ~w(--set coding)) =~ "--set coding: is KEY=VALUE"
  end

  test "won't start a daemon where another holds its name, and says how to use or replace it",
       context do
    {context, log} = script(context)
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")

    pid =
      occupant(context, "/opt/wardrik/0.1.0-rc.5", [
        {~c"HOME", ~c"/home/ops"},
        {~c"XDG_CONFIG_HOME", false},
        {~c"XDG_DATA_HOME", false},
        {~c"WARDRIK_CONFIG_DIR", false},
        {~c"WARDRIK_DATA_HOME", false},
        {~c"WARDRIK_DATA_DIR", false},
        {~c"WARDRIK_ENV_FILE", false}
      ])

    stderr = failing(context, init())

    assert stderr =~
             "Another Wardrik service is running here, from /opt/wardrik/0.1.0-rc.5 (pid #{pid})."

    assert stderr =~ "Use it:      HOME=/home/ops wardrik status"
    assert stderr =~ "Replace it:  kill #{pid}, then wardrik init again"
    refute File.exists?(log)
  end

  # A process that looks to ps like a Wardrik node named as the context's daemon would be.
  defp occupant(context, root, env) do
    beam = Path.join(context.root, "beam.smp")
    File.write!(beam, "#!/bin/sh\nsleep 60\n")
    File.chmod!(beam, 0o755)

    port =
      Port.open({:spawn_executable, beam},
        args: ["--", "-root", root, "-sname", context.env["RELEASE_NODE"]],
        env: env
      )

    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("pkill", ["-P", "#{pid}"], stderr_to_stdout: true)
      System.cmd("kill", ["#{pid}"], stderr_to_stdout: true)
    end)

    Integer.to_string(pid)
  end

  test "names the flag a question needs where no one can answer it", context do
    {context, _log} = script(context)

    assert failing(context, ["init"]) =~
             "no terminal to ask which model provider. Pass --provider"

    assert failing(context, ~w(init --provider anthropic)) =~
             "no terminal to ask for ANTHROPIC_API_KEY. Set it, or pass --key-from-env VAR."

    assert failing(context, ~w(init --provider nobody)) =~
             "--provider nobody isn't a model provider"

    assert failing(context, ~w(init --provider anthropic --model no-such)) =~
             "anthropic has no model no-such. Its newest are claude-"

    assert failing(context, ~w(init --provider anthropic --key-from-env NOPE)) =~
             "--key-from-env NOPE names a variable this environment doesn't set."

    agent = Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents/assistant.md")
    refute File.exists?(agent)
  end

  test "always gives the assistant web_search, and keys Brave in config.yaml where a key is set",
       context do
    {context, _log} = script(context)
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")
    config = Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")
    assistant = Path.join(context.env["WARDRIK_CONFIG_DIR"], "agents/assistant.md")
    File.rm!(config)

    assert {0, _wrote} = wardrik(context, init())
    assert File.read!(config) =~ "# brave:\n#   api_key: ${BRAVE_API_KEY}"

    assert File.read!(assistant) =~
             "tools: [#{Enum.join(Init.assistant_tools(), ", ")}]"

    File.rm!(config)
    File.rm!(assistant)
    context = put_in(context.env["BRAVE_API_KEY"], "bk")

    assert {0, _wrote} = wardrik(context, init())
    assert File.read!(config) =~ ~r/^brave:\n  api_key: \$\{BRAVE_API_KEY\}/m

    assert File.read!(assistant) =~
             "tools: [#{Enum.join(Init.assistant_tools(), ", ")}]"
  end

  test "writes an assistant that the daemon defines, and that makes workers", context do
    {context, _log} = script(context)
    config = Path.join(context.env["WARDRIK_CONFIG_DIR"], "config.yaml")
    File.rm!(config)
    write(context, "env", "ANTHROPIC_API_KEY=sk\n")
    assert {0, _wrote} = wardrik(context, init() ++ ~w(--org acme))

    written =
      config
      |> File.read!()
      |> String.replace("4747", "#{free_port()}")

    File.write!(config, [written, "web: {enabled: false}\n", context.models, "\n"])
    context = start_daemon(context)

    assert {:ok, %Wardrik.Definition{} = front, []} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "assistant"))

    assert front.tools ==
             Init.assistant_tools()

    assert [%{"name" => "check", "every" => "6h"}] =
             Enum.map(front.triggers, &Map.take(Wardrik.Type.json(&1), ["name", "every"]))

    assert front.context == ["MEMORY.md"]
    assert front.idle_timeout == :infinity
    assert front.policy == %{"budget" => %{"tokens" => 2_000_000, "per" => "day"}}
    assert front.instructions =~ "You are Wardrik, the one place the people of this org come"
    assert front.instructions =~ "# Playbook"

    # It makes a worker in its org, once a person approves.
    door = id(context, "acme", "assistant")
    worker = %{"description" => "rivals-watch: watches rivals.", "instructions" => "Watch."}

    answers(context, [
      calling("call_1", "agent_create", %{name: "rivals-watch", definition: worker})
    ])

    assert {:waiting, [%{name: "agent_create"}]} =
             Wardrik.Agent.reply(context.admin, door, "Watch our rivals.")

    # A message after the approval is answered once the approved run is done.
    answers(context, [answer("Made it."), answer("You're welcome.")])
    approve = %{"agent" => door, "interrupt" => "call_1"}
    assert {:ok, _approved} = Wardrik.run(context.admin, "agent.approve", approve)
    assert {:ok, _reply} = Wardrik.Agent.reply(context.admin, door, "Thanks.")

    assert {:ok, %Wardrik.Definition{instructions: "Watch."}, _problems} =
             Wardrik.Agent.definition(context.admin, id(context, "acme", "rivals-watch"))

    # It reads and asks another member's agent, but can't forget, clear, stop or cancel it.
    notes = agent(context, "acme/@jon", "notes")
    acting = Wardrik.as(context.wardrik, "acme", actor: {:agent, door})
    assert {:ok, _snapshot} = Wardrik.run(acting, "agent.read", %{"agent" => notes})

    for action <- ~w(agent.forget agent.clear agent.stop agent.cancel) do
      assert {:error, %Wardrik.Error{type: :forbidden}} =
               Wardrik.run(acting, action, %{"agent" => notes})
    end

    assert {:ok, _definition, _problems} = Wardrik.Agent.definition(context.admin, notes)
  end

  test "says how to start the daemon where it hasn't", context do
    assert failing(context, ["ls"]) =~ "Start it with `wardrik start`"
    assert failing(context, ["nope"]) =~ "nope isn't a command"
    assert failing(context, ["ls", "--colour", "red"]) =~ "--colour isn't an option"
    assert {0, help} = wardrik(context, ["help"])
    assert help =~ "Usage: wardrik COMMAND"
    assert help =~ ~r/Agents\n  agent ls \[QUERY\]\s+list the agents/
    assert help =~ "Shortcuts: ls for agent ls"

    for command <- WardrikDaemon.CLI.commands(),
        command.group,
        do: assert(help =~ command.name, "wardrik help leaves out #{command.name}")

    assert {0, agents} = wardrik(context, ["agent"])
    assert agents =~ "Usage: wardrik agent COMMAND"
    refute agents =~ "token create"

    assert {0, asking} = wardrik(context, ["agent", "ask", "--help"])
    assert asking =~ "Usage: wardrik agent ask AGENT [MESSAGE] [--no-wait]"
    assert asking =~ "Also: wardrik ask"
    assert {0, ^asking} = wardrik(context, ["help", "agent", "ask"])

    assert failing(context, ["agent", "show"]) =~ "Usage: wardrik agent show AGENT"
    assert failing(context, ["start"]) =~ "script runs that itself"
  end

  test "writes completion for bash, zsh and fish", context do
    assert {0, bash} = wardrik(context, ["completion", "bash"])
    assert bash =~ ~s("agent ls"|"agent ls "*|"ls"|"ls "*\) words="--all --json --help")
    assert bash =~ "complete -F _wardrik wardrik rik"

    assert {0, "autoload -U +X bashcompinit && bashcompinit\n" <> _rest} =
             wardrik(context, ["completion", "zsh"])

    assert {0, fish} = wardrik(context, ["completion", "fish"])
    assert fish =~ ~s(complete -c rik -n 'test (__wardrik_words\) = "+agent"' -a cancel -d)
    assert fish =~ ~s(-l no-wait)

    assert failing(context, ["completion", "tcsh"]) =~ "bash, zsh or fish"
    assert failing(context, ["pid"]) =~ "script runs that itself"
  end
end
