defmodule WardrikDaemon.CLI.Init do
  @moduledoc """
  `wardrik init`: from a fresh install to a front door that has answered once.

  No daemon need run yet, so `bin/wardrik` runs it on the release's own VM,
  as it runs help, and it asks at the terminal it was typed in. It says what
  it does at each step:

    1. what is there: the config directory, its agent files, whether a
       daemon runs, and the model providers whose key this environment sets
    2. the model provider, those with a key here first, and the model, the
       provider's newest by default
    3. the provider's key, without showing it, unless this environment sets
       it and that one is kept
    4. the first agent's name, `assistant` by default, and its file in
       `agents/`, the front door, with that model, and `config.yaml`, whose
       `defaults` give that model to the agents `wardrik agent spawn` starts
       and to those the front door defines
    5. the public keys in `~/.ssh`, into `ssh/authorized_keys`, for
       `wardrik attach`
    6. the daemon: under the user's systemd where they have one and want
       it, with `wardrik service install`, and otherwise `wardrik start`; or
       `wardrik reload` where one runs
    7. the key, sealed with `wardrik vault put`, which reads it from
       standard input
    8. the agent, asked one short question with `wardrik ask`
    9. `wardrik doctor`, and the commands to try next

  It writes no file that is there already: it names it, and keeps it. A
  config directory it cannot write, as a container's read-only mount, stops
  it before it asks anything.

  Without a terminal, flags answer: `--provider`, `--model`, `--agent NAME`
  and `--key-from-env VAR`, and `--yes` for each yes or no. A question with
  no default and no flag fails, naming the flag. `--no-service` starts the
  daemon without systemd, and `--no-ask` asks the agent nothing.

  ## The front door

  The first agent is the one place people ask for what they want: it turns
  an outcome into work that runs, defining worker agents of its org with
  the triggers that start them, through `agents/*`, and changing or
  retiring them as it is told, each change waiting on a person. Its file
  gives it `self/*`, `agents/*`, `files` with `MEMORY.md` read into every
  turn, and `web_search`, which answers that it lacks a key where none is
  set, and a budget of 2,000,000 tokens a day, which holds every worker it
  defines too. The budget is in tokens because a model a subscription pays
  for has no price in dollars.

  Its body is its instructions, then a playbook of the shapes of work that
  run well: watching feeds, sweeps that follow a checklist the worker
  keeps, a morning brief, first response to incidents, and acting on what
  is noticed, with the triggers, instructions and budgets each suits. An
  operator edits either in the file, and `wardrik reload` reads it again.
  """

  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Terminal
  alias WardrikDaemon.Config
  alias WardrikDaemon.VaultKey

  @question "In two short sentences, and without calling a tool, say what you can do for me."
  @tokens 2_000_000
  @secret "WARDRIK_INIT_SECRET"

  defstruct [
    :terminal,
    :flags,
    :config_dir,
    :data_dir,
    :home,
    :wardrik,
    :getenv,
    :systemd?,
    :running?,
    :provider,
    :variable,
    :model,
    :key,
    :agent,
    wrote?: false,
    failed?: false
  ]

  @doc "The command, for `WardrikDaemon.CLI.commands/0`."
  @spec command() :: Command.t()
  def command do
    %Command{
      name: "init",
      options:
        "[--provider P] [--model M] [--agent NAME] [--key-from-env VAR] [--yes] " <>
          "[--no-service] [--no-ask]",
      summary: "set up the front door agent, its model and key, and the daemon to run it",
      details: [
        "It asks what it needs, says what it does, and writes no file that is there already.",
        "Without a terminal, --provider, --model, --agent and --key-from-env VAR answer, and",
        "--yes says yes. --no-service starts the daemon without systemd, and --no-ask asks",
        "the agent nothing."
      ],
      switches: [
        provider: :string,
        model: :string,
        agent: :string,
        key_from_env: :string,
        yes: :boolean,
        no_service: :boolean,
        no_ask: :boolean
      ]
    }
  end

  @doc """
  Runs init with the arguments `bin/wardrik` gives it, the terminal ahead of
  the command's own, and stops the VM with its status.
  """
  @spec main([String.t()]) :: no_return()
  def main(args) do
    :logger.set_primary_config(:level, :none)
    {:ok, _started} = Application.ensure_all_started(:req_llm)
    {terminal, ["init" | args]} = Terminal.read(args)
    wardrik = Path.join(System.fetch_env!("RELEASE_ROOT"), "bin/wardrik")
    System.halt(run(terminal, args, wardrik: wardrik))
  end

  @doc """
  Runs init at `terminal` with the flags in `args`, and answers the status to
  exit with: 1 where a step failed, or the agent did not answer, or doctor
  found a fault.

  `opts` say what it works with: `:wardrik`, the script it runs commands
  with; `:config_dir`, `:data_dir` and `:home`; `:getenv`, how it reads the
  environment; and `:systemd`, whether the user has a systemd to run the
  daemon under.
  """
  @spec run(Terminal.t(), [String.t()], keyword()) :: 0 | 1
  def run(terminal, args, opts) do
    with {:ok, _words, flags} <- Command.parse(command(), args),
         {:ok, init} <- steps(new(terminal, flags, opts)) do
      next(init)
      if init.failed?, do: 1, else: 0
    else
      {:error, message} ->
        Terminal.puts(terminal, message)
        1
    end
  end

  defp new(terminal, flags, opts) do
    getenv = Keyword.get(opts, :getenv, &System.get_env/1)

    %__MODULE__{
      terminal: terminal,
      flags: flags,
      wardrik: Keyword.fetch!(opts, :wardrik),
      config_dir: Keyword.get_lazy(opts, :config_dir, &Config.config_dir/0),
      data_dir: Keyword.get_lazy(opts, :data_dir, &Config.data_dir/0),
      home: Keyword.get_lazy(opts, :home, &System.user_home!/0),
      getenv: getenv,
      systemd?: Keyword.get_lazy(opts, :systemd, &systemd?/0)
    }
  end

  defp steps(init) do
    [
      &writable/1,
      &found/1,
      &provider/1,
      &model/1,
      &key/1,
      &agent/1,
      &defaults/1,
      &ssh/1,
      &daemon/1,
      &seal/1,
      &ask/1,
      &doctor/1
    ]
    |> Enum.reduce_while({:ok, init}, fn step, {:ok, init} ->
      case step.(init) do
        {:ok, init} -> {:cont, {:ok, init}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # -- 1. what is there ------------------------------------------------------

  defp writable(%__MODULE__{config_dir: dir} = init) do
    probe = Path.join(dir, ".wardrik-init")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(probe, ""),
         :ok <- File.rm(probe) do
      {:ok, init}
    else
      {:error, reason} ->
        {:error,
         "#{dir} cannot be written (#{:file.format_error(reason)}), and wardrik init writes " <>
           "the first agent there. In Docker, mount a volume there, -v wardrik-config:/config, " <>
           "or a directory of yours that the image's user, uid 1000, can write: " <>
           "-v ~/.config/wardrik:/config"}
    end
  end

  defp found(init) do
    running? = quiet(init, ["pid"]) == 0
    keys = for {_provider, variable} <- providers(), init.getenv.(variable), do: variable

    say(init, [
      "Found:",
      "  config  #{init.config_dir}, with #{config_yaml(init)} and #{agent_files(init)}",
      "  daemon  #{if running?, do: "running", else: "not running"}",
      "  keys    #{keys(keys)}"
    ])

    {:ok, %{init | running?: running?}}
  end

  defp config_yaml(init) do
    case Config.file(init.config_dir) do
      {:ok, file} -> if File.exists?(file), do: Path.basename(file), else: "no config.yaml"
      {:error, _both} -> "config.yaml and config.yml"
    end
  end

  defp agent_files(init) do
    case Path.wildcard(Path.join([init.config_dir, "agents", "*.md"])) do
      [] -> "no agent files"
      [_one] -> "1 agent file"
      files -> "#{length(files)} agent files"
    end
  end

  defp keys([]), do: "no model provider's key in this environment"
  defp keys(variables), do: "#{listed(variables)} in this environment"

  # -- 2. provider and model ---------------------------------------------------

  defp provider(%__MODULE__{flags: flags} = init) do
    providers = providers()

    cond do
      name = flags[:provider] ->
        chosen(init, Enum.find(providers, &(Atom.to_string(elem(&1, 0)) == name)), name)

      init.terminal.input? ->
        {keyed, rest} = Enum.split_with(providers, &init.getenv.(elem(&1, 1)))

        chosen =
          Owl.IO.select(keyed ++ rest,
            label: "Which model provider?",
            render_as: fn {provider, variable} ->
              if init.getenv.(variable),
                do: "#{provider}, whose #{variable} is set here",
                else: Atom.to_string(provider)
            end
          )

        chosen(init, chosen, nil)

      true ->
        {:error,
         "wardrik init has no terminal to ask which model provider; pass --provider, one of " <>
           listed(for {provider, _variable} <- providers, do: Atom.to_string(provider))}
    end
  end

  defp chosen(_init, nil, name),
    do:
      {:error,
       "--provider #{name} is not a model provider wardrik calls; wardrik init lists them"}

  defp chosen(init, {provider, variable}, _name),
    do: {:ok, %{init | provider: provider, variable: variable}}

  defp model(%__MODULE__{flags: flags, provider: provider} = init) do
    [newest | _older] = models = models(provider)

    cond do
      model = flags[:model] ->
        if model?(provider, model, models),
          do: {:ok, %{init | model: model}},
          else: {:error, no_model(provider, model, models)}

      init.terminal.input? ->
        {:ok, %{init | model: ask_model(init, models)}}

      true ->
        {:ok, %{init | model: newest}}
    end
  end

  defp ask_model(%__MODULE__{provider: provider} = init, [newest | older] = models) do
    others = Enum.take(older, 3)
    such_as = if others == [], do: "", else: ", such as #{listed(others, "or")}"

    model =
      Owl.IO.input(
        label: "Which model? #{newest} unless you name another#{such_as}",
        optional: true
      ) || newest

    if model?(provider, model, models) do
      model
    else
      say(init, no_model(provider, model, models))
      ask_model(init, models)
    end
  end

  defp model?(provider, model, models),
    do: model in models or Enum.any?(LLMDB.models(provider), &(&1.id == model))

  defp no_model(provider, model, models),
    do: "#{provider} has no model #{model}; its newest are #{listed(Enum.take(models, 5))}"

  defp providers do
    for provider <- ReqLLM.Providers.list(),
        models(provider) != [],
        do: {provider, ReqLLM.Keys.env_var_name(provider)}
  end

  defp models(provider) do
    provider
    |> LLMDB.models()
    |> Enum.filter(&current?/1)
    |> Enum.sort_by(&(&1.release_date || ""), :desc)
    |> Enum.map(& &1.id)
  end

  defp current?(model) do
    (model.capabilities || %{})[:chat] != false and not model.deprecated and
      not model.retired and model.catalog_only != true
  end

  # -- 3. the key --------------------------------------------------------------

  defp key(%__MODULE__{flags: flags, variable: variable} = init) do
    cond do
      from = flags[:key_from_env] ->
        case init.getenv.(from) do
          nil -> {:error, "--key-from-env #{from} names a variable this environment does not set"}
          key -> {:ok, %{init | key: key}}
        end

      kept = kept(init) ->
        {:ok, %{init | key: kept}}

      init.terminal.input? ->
        typed(init)

      true ->
        {:error,
         "wardrik init has no terminal to ask for #{variable}; set it, or pass --key-from-env VAR"}
    end
  end

  defp kept(%__MODULE__{variable: variable} = init) do
    with key when is_binary(key) <- init.getenv.(variable),
         true <- not init.terminal.input? or confirm(init, "Keep the #{variable} set here?") do
      key
    else
      _none_or_declined -> nil
    end
  end

  defp typed(%__MODULE__{variable: variable} = init) do
    case Terminal.secret(init.terminal, "#{variable}, which is not shown as you type: ") do
      {:ok, nil} ->
        say(
          init,
          "No key, so the agent cannot answer until wardrik vault put #{variable} seals one."
        )

        {:ok, init}

      {:ok, key} ->
        {:ok, %{init | key: key}}

      {:error, message} ->
        {:error, message}
    end
  end

  # -- 4. the agent ------------------------------------------------------------

  defp agent(%__MODULE__{flags: flags} = init) do
    name =
      cond do
        flags[:agent] ->
          flags[:agent]

        init.terminal.input? ->
          Owl.IO.input(label: "Its name? assistant unless you name another", optional: true) ||
            "assistant"

        true ->
          "assistant"
      end

    if Wardrik.AgentID.segment?(name),
      do: write_agent(%{init | agent: name}),
      else:
        {:error,
         "#{name} is not an agent's name: a name holds no / or whitespace, and does not " <>
           "begin with @ or _"}
  end

  defp write_agent(%__MODULE__{agent: name} = init) do
    file = Path.join([init.config_dir, "agents", name <> ".md"])

    if File.exists?(file) do
      say(init, "agents/#{name}.md is there already, so it is kept as it is.")
      {:ok, init}
    else
      File.mkdir_p!(Path.dirname(file))

      File.write!(
        file,
        AgentFile.text(
          [
            {"description", "The front door: turns what people ask for into work that runs."},
            {"model", "#{init.provider}:#{init.model}"},
            {"tools", ["self/*", "agents/*", "files", "web_search"]},
            {"context", ["MEMORY.md"]},
            {"policy", %{"budget" => %{"tokens" => @tokens, "per" => "day"}}},
            {"idle_timeout", "infinity"}
          ],
          File.read!(Application.app_dir(:wardrik_daemon, "priv/front_door.md"))
        )
      )

      say(init, [
        "Wrote agents/#{name}.md, the front door, which runs #{init.provider}:#{init.model}.",
        "Tell it what you want done: it proposes the work, waits for your approval, and runs it.",
        "Its instructions and playbook are the body of that file, to edit as you like."
      ])

      {:ok, %{init | wrote?: true}}
    end
  end

  # A config.yaml that is there is kept, and says what to add where it gives
  # no defaults.
  defp defaults(init) do
    model = "#{init.provider}:#{init.model}"

    case Config.file(init.config_dir) do
      {:ok, file} ->
        if File.exists?(file), do: kept(init, file, model), else: write_config(init, file, model)

      {:error, _both} ->
        {:ok, init}
    end
  end

  defp write_config(init, file, model) do
    File.write!(file, "defaults:\n  model: #{model}\n")

    say(init, [
      "Wrote config.yaml, whose defaults give an agent wardrik agent spawn starts #{model} too."
      | if(init.running?, do: ["The daemon reads it when it next starts."], else: [])
    ])

    {:ok, init}
  end

  defp kept(init, file, model) do
    case Config.read(file, only: ["defaults"]) do
      {:ok, settings} ->
        unless Keyword.has_key?(settings, WardrikDaemon.Agents) do
          say(
            init,
            "#{Path.basename(file)} gives no defaults; defaults: with model: #{model} in it " <>
              "gives an agent wardrik agent spawn starts the same model."
          )
        end

      {:error, _unread} ->
        :ok
    end

    {:ok, init}
  end

  # -- 5. ssh ------------------------------------------------------------------

  defp ssh(init) do
    authorized = Path.join([init.config_dir, "ssh", "authorized_keys"])
    keys = Path.wildcard(Path.join([init.home, ".ssh", "*.pub"]))

    cond do
      File.exists?(authorized) or keys == [] ->
        {:ok, init}

      confirm(init, "Let #{listed(Enum.map(keys, &Path.basename/1))} in, for wardrik attach?") ->
        File.mkdir_p!(Path.dirname(authorized))
        File.write!(authorized, Enum.map(keys, &File.read!/1))
        File.chmod!(authorized, 0o600)
        say(init, "Wrote ssh/authorized_keys, so wardrik attach reaches the TUI with those keys.")
        {:ok, init}

      true ->
        {:ok, init}
    end
  end

  # -- 6. the daemon -----------------------------------------------------------

  defp daemon(%__MODULE__{running?: true, wrote?: true} = init) do
    say(init, "The daemon runs, so it reads the new agent file with wardrik reload.")
    started(init, ["reload"])
  end

  defp daemon(%__MODULE__{running?: true} = init), do: {:ok, init}

  defp daemon(init) do
    if init.systemd? and init.flags[:no_service] != true and
         confirm(init, "Run the daemon under your user's systemd, from boot?") do
      started(init, ["service", "install"])
    else
      with {:ok, init} <- started(init, ["start"]) do
        say(init, "Started the daemon.")
        {:ok, init}
      end
    end
  end

  # The daemon reads the key from the vault, as it will once restarted.
  defp started(init, args) do
    case loud(init, args, env: [{init.variable, nil}]) do
      0 -> {:ok, %{init | running?: true}}
      _failed -> {:error, "wardrik #{Enum.join(args, " ")} did not succeed, so init stops here."}
    end
  end

  # -- 7. the key in the vault -------------------------------------------------

  defp seal(%__MODULE__{key: nil} = init), do: {:ok, init}

  defp seal(init) do
    with {:ok, yes} <- vault_key(init) do
      script = ~s(printf %s "$#{@secret}" | env -u #{@secret} "$0" vault put "$@")

      case streamed("sh", ["-c", script, init.wardrik, init.variable | yes],
             env: [{@secret, init.key}]
           ) do
        0 -> {:ok, init}
        _failed -> {:error, "#{init.variable} was not sealed, so init stops here."}
      end
    end
  end

  defp vault_key(init) do
    cond do
      vault_keyed?(init) ->
        {:ok, []}

      init.terminal.input? ->
        say(init, [
          "The vault, which keeps #{init.variable}, has no key of its own yet."
          | Enum.map(VaultKey.about(), &("  " <> &1))
        ])

        if confirm(init, "Make one?"),
          do: {:ok, ["--yes"]},
          else: {:error, "Nothing was sealed, so init stops here."}

      init.flags[:yes] ->
        {:ok, ["--yes"]}

      true ->
        {:error,
         "The vault has no key of its own to seal #{init.variable} with; pass --yes to make " <>
           "one, or set WARDRIK_VAULT_KEY"}
    end
  end

  defp vault_keyed?(init) do
    with {:ok, file} <- Config.file(init.config_dir),
         {:ok, settings} <- Config.read(file, only: ["vault"]) do
      init.getenv.("WARDRIK_VAULT_KEY") != nil or settings[WardrikVault][:keys] not in [nil, []] or
        match?({:ok, _key}, VaultKey.read(VaultKey.file(init.data_dir)))
    else
      {:error, _unread} -> false
    end
  end

  # -- 8. and 9. the agent's answer, and doctor -------------------------------

  defp ask(%__MODULE__{flags: flags} = init) do
    if flags[:no_ask] do
      {:ok, init}
    else
      say(init, "Asking #{init.agent}: #{@question}")

      case loud(init, ["ask", init.agent, @question]) do
        0 ->
          {:ok, init}

        _failed ->
          say(init, [
            "#{init.agent} did not answer. The usual reason is its key, which",
            "wardrik vault put #{init.variable} seals again. Its file stays as it is."
          ])

          {:ok, %{init | failed?: true}}
      end
    end
  end

  defp doctor(init) do
    case loud(init, ["doctor"]) do
      0 -> {:ok, init}
      _fault -> {:ok, %{init | failed?: true}}
    end
  end

  defp next(init) do
    rows = [
      {"wardrik ask #{init.agent} MESSAGE", "tell it what you want done, and follow its answer"},
      {"wardrik parked", "what it proposes, waiting on your approval"},
      {"wardrik approve", "approve it, or wardrik deny to refuse it"},
      {"wardrik ls", "the agents running, the workers it defines among them"},
      {"wardrik attach", "the TUI, over SSH"},
      {"wardrik completion SHELL", "completion for bash, zsh or fish"}
    ]

    width = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()

    say(init, [
      "",
      "Next, try: wardrik ask #{init.agent} \"Tell me when https://elixir-lang.org/atom.xml has a new post\"",
      "",
      "Then:"
      | for({command, what} <- rows, do: "  #{String.pad_trailing(command, width)}  #{what}")
    ])
  end

  # -- the terminal and the commands it runs -----------------------------------

  defp confirm(%__MODULE__{terminal: %Terminal{input?: true}}, question),
    do: Owl.IO.confirm(message: question, default: true)

  defp confirm(init, _question), do: init.flags[:yes] == true

  defp say(init, lines) when is_list(lines),
    do: Terminal.puts(init.terminal, Enum.join(lines, "\n"))

  defp say(init, line), do: Terminal.puts(init.terminal, line)

  defp quiet(init, args) do
    {_output, status} = System.cmd(init.wardrik, args, stderr_to_stdout: true)
    status
  end

  defp loud(init, args, opts \\ []), do: streamed(init.wardrik, args, opts)

  defp streamed(command, args, opts) do
    {_output, status} =
      System.cmd(command, args, [into: IO.stream(), stderr_to_stdout: true] ++ opts)

    status
  end

  defp systemd? do
    match?({:unix, :linux}, :os.type()) and System.find_executable("systemctl") != nil and
      match?(
        {_out, 0},
        System.cmd("systemctl", ["--user", "show-environment"], stderr_to_stdout: true)
      )
  end

  defp listed(items, word \\ "and")
  defp listed([only], _word), do: only

  defp listed(items, word),
    do:
      IO.iodata_to_binary([
        Enum.join(Enum.drop(items, -1), ", "),
        " ",
        word,
        " ",
        List.last(items)
      ])
end
