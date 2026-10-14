defmodule WardrikDaemon.CLI.InitTest do
  use ExUnit.Case, async: false

  alias WardrikDaemon.Test.Host

  # Commands run over rpc build their callers on the daemon's host.
  setup do: Host.held()

  import ExUnit.CaptureIO

  alias WardrikDaemon.CLI
  alias WardrikDaemon.CLI.Init
  alias WardrikDaemon.CLI.Terminal

  @moduletag :tmp_dir

  # Stands in for bin/wardrik: it writes each command it is given to the log,
  # with what came on standard input and whether the key came in its
  # environment, and answers as the variables the test sets say.
  @wardrik """
  #!/bin/sh
  echo "$* key=${ANTHROPIC_API_KEY:-unset} secret=${WARDRIK_INIT_SECRET:-unset}" >> "$WARDRIK_FAKE_LOG"
  case "$1" in
    pid) [ -n "$WARDRIK_FAKE_RUNNING" ] || exit 1; echo 123 ;;
    vault) echo "stdin=$(cat)" >> "$WARDRIK_FAKE_LOG"; echo "Sealed $3." ;;
    ask) echo "Hello, I can help."; exit "${WARDRIK_FAKE_ASK:-0}" ;;
    doctor) echo "ok    config  reads" ;;
  esac
  """

  setup %{tmp_dir: dir} do
    wardrik = Path.join(dir, "wardrik")
    File.write!(wardrik, @wardrik)
    File.chmod!(wardrik, 0o755)

    log = Path.join(dir, "log")
    variables = ~w(WARDRIK_FAKE_LOG WARDRIK_FAKE_RUNNING WARDRIK_FAKE_ASK ANTHROPIC_API_KEY)
    previous = Map.new(variables, &{&1, System.get_env(&1)})
    System.put_env("WARDRIK_FAKE_LOG", log)
    Enum.each(tl(variables), &System.delete_env/1)

    on_exit(fn ->
      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    opts = [
      wardrik: wardrik,
      config_dir: Path.join(dir, "config"),
      data_dir: Path.join(dir, "data"),
      home: Path.join(dir, "home"),
      getenv: fn _name -> nil end,
      systemd: false
    ]

    %{opts: opts, log: log, config: Path.join(dir, "config")}
  end

  defp init(args, input, opts, terminal \\ %Terminal{input?: true}) do
    parent = self()
    output = capture_io(input, fn -> send(parent, {:status, Init.run(terminal, args, opts)}) end)
    assert_receive {:status, status}
    {output, status}
  end

  defp alone(args, opts), do: init(args, "", opts, %Terminal{})

  defp env(map), do: fn name -> Map.get(map, name) end

  defp plain(data), do: data |> WardrikConsole.Ansi.chardata(false) |> IO.chardata_to_string()

  defp log(log), do: if(File.exists?(log), do: File.read!(log), else: "")

  test "asks each step at a terminal, and takes a key this environment sets", %{
    opts: opts,
    log: log,
    config: config
  } do
    opts = Keyword.put(opts, :getenv, env(%{"ANTHROPIC_API_KEY" => "sk-from-env"}))

    {output, 0} = init([], "1\n\n\n\n\n", opts)

    assert output =~ "Found:\n  config  #{config}, with no config.yaml and no agent files"
    assert output =~ "  daemon  not running"
    assert output =~ "  keys    ANTHROPIC_API_KEY in this environment"
    assert output =~ "anthropic, whose ANTHROPIC_API_KEY is set here"
    assert output =~ "Keep the ANTHROPIC_API_KEY set here?"
    assert output =~ "Wrote agents/assistant.md, the front door, which runs anthropic:"
    assert output =~ "it proposes the work, waits for your approval, and runs it."
    assert output =~ "The vault, which keeps ANTHROPIC_API_KEY, has no key of its own yet."
    assert output =~ "Hello, I can help."
    assert output =~ "Next, try: wardrik ask assistant \"Tell me when"

    assert output =~
             "  wardrik ask assistant MESSAGE  tell it what you want done, and follow its answer"

    assert output =~ "  wardrik approve                approve it, or wardrik deny to refuse it"

    text = File.read!(Path.join(config, "agents/assistant.md"))
    assert text =~ ~r/\A---\ndescription: .*\nmodel: anthropic:\S+\n/

    assert text =~
             "\ntools: [self/*, agents/*, files, web_search]\ncontext: [MEMORY.md]\n" <>
               "policy: {budget: {per: day, tokens: 2000000}}\nidle_timeout: infinity\n---\n" <>
               "You are Wardrik, the one place"

    assert text =~ "\n# Playbook\n"

    assert {:ok, _spec} =
             WardrikDaemon.AgentFile.read(
               WardrikDaemon.AgentFile.context(Host.config(config)),
               Path.join(config, "agents/assistant.md")
             )

    commands = log(log)
    assert commands =~ "start key=unset"

    assert commands =~
             "vault put ANTHROPIC_API_KEY --yes key=unset secret=unset\nstdin=sk-from-env"

    assert commands =~ "ask assistant In two short sentences"
    assert commands =~ "doctor"
  end

  test "asks for a key it does not show, lets SSH keys in, and runs the daemon under systemd",
       %{opts: opts, log: log, config: config, tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "home/.ssh"))
    File.write!(Path.join(dir, "home/.ssh/id_ed25519.pub"), "ssh-ed25519 AAAA me@here\n")
    opts = Keyword.put(opts, :systemd, true)

    {output, 0} = init(["--provider", "anthropic"], "\nsk-typed\ntriage\n\n\n\n", opts)

    refute output =~ "sk-typed"
    assert output =~ "ANTHROPIC_API_KEY, which is not shown as you type:"
    assert output =~ "Let id_ed25519.pub in, for wardrik attach?"
    assert output =~ "Run the daemon under your user's systemd, from boot?"
    assert File.exists?(Path.join(config, "agents/triage.md"))

    authorized = Path.join(config, "ssh/authorized_keys")
    assert File.read!(authorized) == "ssh-ed25519 AAAA me@here\n"
    assert Bitwise.band(File.stat!(authorized).mode, 0o777) == 0o600

    commands = log(log)
    assert commands =~ "service install"
    assert commands =~ "stdin=sk-typed"
    assert commands =~ "ask triage"
  end

  test "answers every question from its flags where no one can type", %{
    opts: opts,
    log: log,
    config: config
  } do
    opts = Keyword.merge(opts, getenv: env(%{"MY_KEY" => "sk-flag"}), systemd: true)

    flags =
      ~w(--provider anthropic --model claude-sonnet-5 --agent bot --key-from-env MY_KEY --yes
         --no-service --no-ask)

    {output, 0} = alone(flags, opts)

    assert File.read!(Path.join(config, "agents/bot.md")) =~ "model: anthropic:claude-sonnet-5\n"

    assert File.read!(Path.join(config, "config.yaml")) ==
             "defaults:\n  model: anthropic:claude-sonnet-5\n"

    assert output =~
             "Wrote config.yaml, whose defaults give an agent wardrik agent spawn starts " <>
               "anthropic:claude-sonnet-5 too."

    commands = log(log)
    assert commands =~ "start"
    refute commands =~ "service install"
    assert commands =~ "vault put ANTHROPIC_API_KEY --yes"
    assert commands =~ "stdin=sk-flag"
    refute commands =~ "ask "
  end

  test "names the flag a question needs where no one can answer it", %{opts: opts} do
    assert {output, 1} = alone([], opts)
    assert output =~ "wardrik init has no terminal to ask which model provider; pass --provider"

    assert {output, 1} = alone(~w(--provider anthropic), opts)

    assert output =~
             "no terminal to ask for ANTHROPIC_API_KEY; set it, or pass --key-from-env VAR"

    opts = Keyword.put(opts, :getenv, env(%{"ANTHROPIC_API_KEY" => "sk"}))
    assert {output, 1} = alone(~w(--provider anthropic --no-ask), opts)
    assert output =~ "pass --yes to make one, or set WARDRIK_VAULT_KEY"

    assert {output, 1} = alone(~w(--provider nobody), opts)
    assert output =~ "--provider nobody is not a model provider wardrik calls"

    assert {output, 1} = alone(~w(--provider anthropic --model no-such-model), opts)
    assert output =~ "anthropic has no model no-such-model; its newest are"

    assert {output, 1} = alone(~w(--provider anthropic --agent @me), opts)
    assert output =~ "@me is not an agent's name"
  end

  test "keeps what is there, and asks a running daemon to read a new file", %{
    opts: opts,
    log: log,
    config: config,
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, "data"))
    File.write!(Path.join(dir, "data/vault_key"), WardrikVault.generate_key())
    opts = Keyword.put(opts, :getenv, env(%{"ANTHROPIC_API_KEY" => "sk"}))
    flags = ~w(--provider anthropic --no-ask)

    {_output, 0} = alone(flags, opts)
    written = File.read!(Path.join(config, "agents/assistant.md"))
    assert log(log) =~ "start"
    refute log(log) =~ "--yes"

    File.rm!(log)
    System.put_env("WARDRIK_FAKE_RUNNING", "1")
    {output, 0} = alone(flags, opts)

    assert output =~ "  daemon  running"
    assert output =~ "agents/assistant.md is there already, so it is kept as it is."
    assert File.read!(Path.join(config, "agents/assistant.md")) == written
    refute log(log) =~ "start"
    refute log(log) =~ "reload"

    File.rm!(Path.join(config, "agents/assistant.md"))
    {output, 0} = alone(flags, opts)
    assert output =~ "The daemon runs, so it reads the new agent file with wardrik reload."
    assert log(log) =~ "reload"
  end

  test "keeps a config.yaml that is there, and says what its defaults could be", %{
    opts: opts,
    config: config
  } do
    opts = Keyword.put(opts, :getenv, env(%{"MY_KEY" => "sk"}))
    flags = ~w(--provider anthropic --model claude-sonnet-5 --key-from-env MY_KEY --yes --no-ask)
    File.mkdir_p!(config)
    File.write!(Path.join(config, "config.yaml"), "org: acme\n")

    {output, 0} = alone(flags, opts)
    assert File.read!(Path.join(config, "config.yaml")) == "org: acme\n"

    assert output =~
             "config.yaml gives no defaults; defaults: with model: anthropic:claude-sonnet-5 " <>
               "in it gives an agent wardrik agent spawn starts the same model."

    File.write!(Path.join(config, "config.yaml"), "defaults:\n  model: anthropic:other\n")
    {output, 0} = alone(flags, opts)
    refute output =~ "gives no defaults"

    File.rm!(Path.join(config, "config.yaml"))
    System.put_env("WARDRIK_FAKE_RUNNING", "1")
    {output, 0} = alone(flags, opts)
    assert output =~ "Wrote config.yaml, whose defaults"
    assert output =~ "The daemon reads it when it next starts."
  end

  test "keeps the files where the agent does not answer, and names the fix", %{
    opts: opts,
    config: config
  } do
    System.put_env("WARDRIK_FAKE_ASK", "1")
    opts = Keyword.put(opts, :getenv, env(%{"ANTHROPIC_API_KEY" => "sk"}))

    {output, 1} = alone(~w(--provider anthropic --yes), opts)

    assert output =~ "assistant did not answer. The usual reason is its key"
    assert output =~ "wardrik vault put ANTHROPIC_API_KEY seals again"
    assert File.exists?(Path.join(config, "agents/assistant.md"))
  end

  test "stops before asking anything where it cannot write the config directory", %{
    opts: opts,
    log: log,
    config: config
  } do
    File.mkdir_p!(config)
    File.chmod!(config, 0o500)
    on_exit(fn -> File.chmod!(config, 0o700) end)

    {output, 1} = init([], "", opts)

    assert output =~ "#{config} cannot be written"
    assert output =~ "-v wardrik-config:/config"
    refute output =~ "Found:"
    assert log(log) == ""
  end

  test "help points at init until there is an agent file", %{config: config} do
    previous = System.get_env("WARDRIK_CONFIG_DIR")
    System.put_env("WARDRIK_CONFIG_DIR", config)

    on_exit(fn ->
      if previous,
        do: System.put_env("WARDRIK_CONFIG_DIR", previous),
        else: System.delete_env("WARDRIK_CONFIG_DIR")
    end)

    {:ok, help} = CLI.unanswered([], %Terminal{})
    assert plain(help) =~ "No agent files yet: wardrik init sets one up."

    File.mkdir_p!(Path.join(config, "agents"))
    File.write!(Path.join(config, "agents/assistant.md"), "You help.\n")
    {:ok, help} = CLI.unanswered([], %Terminal{})
    refute plain(help) =~ "No agent files yet"
  end
end
