defmodule WardrikDaemon.CLI.Init do
  @moduledoc false

  alias WardrikDaemon.CLI.Access
  alias WardrikDaemon.CLI.Answers
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Follow
  alias WardrikDaemon.CLI.Occupant
  alias WardrikDaemon.CLI.Terminal
  alias WardrikDaemon.Dirs
  alias WardrikDaemon.EnvFile
  alias WardrikDaemon.Setup

  @question "In two short sentences, and without calling a tool, say what you can do for me."
  @models %{anthropic: "claude-haiku-4-5"}

  @doc "Returns the `init` command."
  @spec command() :: Command.t()
  def command do
    %Command{
      name: "init",
      group: "Set up",
      switches: [
        org: :string,
        provider: :string,
        model: :string,
        key_from_env: :string,
        yes: :boolean,
        no_service: :boolean,
        no_ask: :boolean,
        set: :keep,
        answers: :string
      ],
      summary: "set up the assistant, its model and key, and the daemon to run it",
      details: [
        "It asks what it needs and never overwrites a file. Without a terminal, use --provider,",
        "--model and --key-from-env VAR. --yes installs the systemd service, --no-service skips",
        "it, and --no-ask skips the first question. --org names the org (default: default).",
        "",
        "Then it offers what it finds here, such as Claude Code for coding. --set KEY=VALUE and",
        "--answers FILE, YAML or - for stdin, answer the offers, as --set coding.claude=true.",
        "Without a terminal, an offer no one answers takes --yes. It never installs anything: it",
        "shows the commands to run."
      ],
      run: &run/3
    }
  end

  defp run([], flags, cx) do
    found(cx)

    with {:ok, given} <- Answers.given(flags),
         {:ok, provider, variable} <- provider(flags, cx),
         {:ok, model} <- model(flags, cx, provider),
         {:ok, key} <- key(flags, cx, variable),
         wrote = write(cx, flags, "#{provider}:#{model}"),
         {:ok, set_up, commands} <- set_up(cx, given, flags),
         cx = %{Context.new(cx.env) | terminal: cx.terminal},
         seal = fn -> sealed(cx, variable, key) end,
         :ok <- daemon(flags, cx, wrote ++ set_up, seal, key != nil or flags[:no_ask] != true),
         :ok <- ask(flags, cx, variable) do
      next(cx, commands)
    end
  end

  defp set_up(cx, given, flags) do
    machine = Setup.Machine.new(cx.env, cx.dirs)

    with {:ok, changes, asked} <-
           Setup.plan(Setup.steps(), machine, Answers.answer(cx, given, flags)),
         :ok <- unasked(cx, Answers.unasked(given, asked)),
         {:ok, done} <- Setup.apply(changes, cx.dirs) do
      for {said, path} when said in [:wrote, :kept] <- done,
          do: Context.puts(cx, said(said, path))

      {:ok, for({:wrote, path} <- done, do: path),
       for({:command, command, why} <- done, do: {command, why})}
    end
  end

  defp unasked(cx, lines),
    do: Enum.each(lines, &Context.puts(cx, [Owl.Data.tag("! ", :yellow), &1]))

  defp said(:wrote, path), do: [Owl.Data.tag("Wrote", :green), " ", path]
  defp said(:kept, path), do: [Owl.Data.tag("Kept ", :light_black), " ", path]

  defp found(cx) do
    case for({_provider, variable} <- providers(), cx.env[variable], uniq: true, do: variable) do
      [] -> Context.puts(cx, "Found no model provider's key here.")
      keys -> Context.puts(cx, "Found #{Enum.join(keys, ", ")} here.")
    end
  end

  defp provider(%{provider: name}, _cx) do
    case Enum.find(providers(), &(Atom.to_string(elem(&1, 0)) == name)) do
      {provider, variable} -> {:ok, provider, variable}
      nil -> {:error, "--provider #{name} isn't a model provider Wardrik calls."}
    end
  end

  defp provider(_flags, %{terminal: %Terminal{input?: true}} = cx) do
    {keyed, rest} = Enum.split_with(providers(), &cx.env[elem(&1, 1)])

    {provider, variable} =
      Owl.IO.select(keyed ++ rest,
        label: "Which model provider?",
        render_as: fn {provider, variable} ->
          if cx.env[variable],
            do: "#{provider}, whose #{variable} is set here",
            else: "#{provider}"
        end
      )

    {:ok, provider, variable}
  end

  defp provider(_flags, _cx),
    do:
      {:error,
       "There's no terminal to ask which model provider. Pass --provider, as --provider anthropic."}

  defp model(%{model: model}, _cx, provider) do
    if model?(provider, model),
      do: {:ok, model},
      else: {:error, "#{provider} has no model #{model}. Its newest are #{newest(provider)}."}
  end

  defp model(_flags, %{terminal: %Terminal{input?: true}} = cx, provider) do
    default = default(provider)

    model =
      Owl.IO.input(label: "Which model? #{default} unless you name another.", optional: true) ||
        default

    if model?(provider, model) do
      {:ok, model}
    else
      Context.puts(cx, "#{provider} has no model #{model}. Its newest are #{newest(provider)}.")
      model(%{}, cx, provider)
    end
  end

  defp model(_flags, _cx, provider), do: {:ok, default(provider)}

  defp default(provider), do: Map.get_lazy(@models, provider, fn -> hd(models(provider)) end)

  defp model?(provider, model), do: match?({:ok, _model}, LLMDB.model({provider, model}))

  defp newest(provider), do: provider |> models() |> Enum.take(5) |> Enum.join(", ")

  defp providers do
    for provider <- ReqLLM.Providers.list(),
        models(provider) != [],
        do: {provider, ReqLLM.Keys.env_var_name(provider)}
  end

  defp models(provider) do
    provider
    |> LLMDB.models()
    |> Enum.reject(&(&1.deprecated or &1.retired or (&1.capabilities || %{})[:chat] == false))
    |> Enum.sort_by(&(&1.release_date || ""), :desc)
    |> Enum.map(& &1.id)
  end

  defp key(%{key_from_env: from}, cx, _variable) do
    case cx.env[from] do
      nil -> {:error, "--key-from-env #{from} names a variable this environment doesn't set."}
      key -> {:ok, key}
    end
  end

  defp key(_flags, cx, variable) do
    cond do
      Map.has_key?(EnvFile.load(cx.dirs.env_file, %{}), variable) ->
        Context.puts(cx, "#{variable} is read from #{cx.dirs.env_file}.")
        {:ok, nil}

      key = cx.env[variable] ->
        Context.puts(cx, "#{variable} is set here, so it's sealed in the vault for the daemon.")
        {:ok, key}

      cx.terminal.input? ->
        typed(cx, variable)

      true ->
        {:error,
         "There's no terminal to ask for #{variable}. Set it, or pass --key-from-env VAR."}
    end
  end

  defp typed(cx, variable) do
    case Terminal.secret(cx.terminal, "#{variable}, not shown as you type: ") do
      nil ->
        Context.puts(
          cx,
          "No key, so the assistant can't answer until #{cx.program} vault put #{variable} --for api_key seals one."
        )

        {:ok, nil}

      key ->
        {:ok, key}
    end
  end

  defp write(cx, flags, model) do
    search? = Map.has_key?(cx.env, "BRAVE_API_KEY")

    wrote =
      for {name, text, mode} <- [
            {"config.yaml", config(Map.get(flags, :org, "default"), model, search?), 0o644},
            {"agents/assistant.md", assistant(), 0o644},
            {"env", env(), 0o600}
          ],
          written?(cx, Dirs.config(cx.dirs, name), text, mode),
          do: name

    unless "config.yaml" in wrote or modelled?(cx.dirs),
      do:
        Context.puts(
          cx,
          "config.yaml names no default model, so the assistant has none. Add it:\n" <>
            "  defaults:\n    model: #{model}"
        )

    wrote
  end

  defp modelled?(dirs) do
    match?(
      {:ok, %{"defaults" => %{"model" => _model}}},
      YamlElixir.read_from_file(Dirs.config(dirs, "config.yaml"))
    )
  end

  defp written?(cx, path, text, mode) do
    if File.exists?(path) do
      Context.puts(cx, said(:kept, path))
      false
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
      File.chmod!(path, mode)
      Context.puts(cx, said(:wrote, path))
      true
    end
  end

  # A reload that finds config.yaml changed restarts the daemon after it answers, so a running
  # daemon is given the key first.
  defp daemon(flags, cx, wrote, seal, needed?) do
    case Context.call(cx, "deployment.nodes", %{}) do
      {:ok, _nodes} -> with :ok <- elsewhere(cx), :ok <- seal.(), do: running(cx, wrote)
      {:error, _down} -> with :ok <- vacant(cx), :ok <- started(flags, cx, needed?), do: seal.()
    end
  end

  # The daemon this CLI reaches runs from another release, as a checkout's or an older install's.
  defp elsewhere(%{env: %{"WARDRIK_SCRIPT" => script}} = cx) do
    ours = script |> Path.dirname() |> Path.dirname()

    case Occupant.find(cx.env) do
      %Occupant{root: root} = occupant when root != ours ->
        Context.puts(cx, [
          Owl.Data.tag("! ", :yellow),
          Occupant.told(occupant, cx.env, cx.program, true)
        ])

      _ours ->
        :ok
    end
  end

  defp elsewhere(_cx), do: :ok

  # A node this CLI can't reach holds the name a new daemon would take, so it couldn't start.
  defp vacant(cx) do
    case Occupant.find(cx.env) do
      nil -> :ok
      occupant -> {:error, Occupant.told(occupant, cx.env, cx.program, false)}
    end
  end

  defp running(_cx, []), do: :ok
  defp running(cx, _wrote), do: reloaded(cx, Context.call(cx, "deployment.reload", %{}))

  defp reloaded(cx, {:ok, answer}) do
    Context.puts(cx, "The daemon runs, and read what init wrote.")

    for problem <- Map.get(answer, "problems", []),
        do: Context.puts(cx, [Owl.Data.tag("! ", :yellow), "Wardrik ", problem])

    :ok
  end

  defp reloaded(_cx, {:error, why}), do: {:error, why}

  defp started(flags, %{env: %{"WARDRIK_SCRIPT" => script}} = cx, needed?) do
    args = if service?(flags, cx), do: ["service", "install"], else: ["start"]

    case System.cmd(script, args, into: IO.stream(), stderr_to_stdout: true) do
      {_output, 0} -> if needed?, do: answered(cx), else: :ok
      {_output, _failed} -> {:error, "#{cx.program} #{Enum.join(args, " ")} failed."}
    end
  end

  defp started(_flags, _cx, _needed?),
    do:
      {:error,
       "The daemon isn't running. Start it, as with mix wardrik serve, and run init again."}

  defp service?(%{no_service: true}, _cx), do: false

  defp service?(flags, cx) do
    systemd?() and
      if cx.terminal.input?,
        do: Owl.IO.confirm(message: "Run the daemon as a systemd user service?", default: true),
        else: flags[:yes] == true
  end

  defp systemd? do
    System.find_executable("systemctl") != nil and
      match?(
        {_out, 0},
        System.cmd("systemctl", ["--user", "show-environment"], stderr_to_stdout: true)
      )
  end

  defp answered(cx),
    do:
      Terminal.spinning(cx.terminal, "Waiting for the daemon to answer", fn ->
        answering(cx, 60)
      end)

  defp answering(cx, 0),
    do: {:error, "The daemon didn't answer in a minute. #{logged(cx)}"}

  defp answering(cx, tries) do
    case Context.call(cx, "deployment.nodes", %{}) do
      {:ok, _nodes} ->
        :ok

      {:error, _starting} ->
        Process.sleep(1_000)
        answering(cx, tries - 1)
    end
  end

  defp logged(cx) do
    case Path.wildcard(Path.join([cx.dirs.state, "log", "erlang.log.*"])) do
      [] ->
        "It logged nothing to #{Path.join(cx.dirs.state, "log")}."

      logs ->
        log = Enum.max_by(logs, &File.stat!(&1, time: :posix).mtime)
        last = log |> File.read!() |> String.split("\n", trim: true) |> Enum.take(-10)
        "The end of its log, #{log}:\n\n  #{Enum.join(last, "\n  ")}\n\nMore: #{cx.program} logs"
    end
  end

  defp sealed(_cx, _variable, nil), do: :ok

  defp sealed(cx, variable, key),
    do: Access.seal(cx, owner: "deployment", name: variable, value: key, purpose: "api_key")

  defp ask(%{no_ask: true}, _cx, _variable), do: :ok

  defp ask(_flags, cx, variable) do
    Context.puts(cx, "Asking the assistant: #{@question}")

    answered =
      with {:ok, id} <- Context.agent(cx, "assistant"),
           do: Follow.turn(cx, agent: id, name: "assistant", text: @question)

    case answered do
      :ok ->
        :ok

      {:error, why} ->
        {:error,
         "The assistant didn't answer: #{why} The usual reason is its key, which " <>
           "#{cx.program} vault put #{variable} --for api_key seals again."}
    end
  end

  defp next(cx, commands) do
    Context.puts(cx, [
      "\n",
      Owl.Box.new(
        to_run(commands) ++
          [
            "Tell it what you want done:\n",
            Owl.Data.tag(
              ~s(#{cx.program} ask assistant "Tell me when https://github.blog/changelog/feed/ has a new post"),
              :cyan
            ),
            "\n\nIt proposes the work, and waits for you: ",
            Owl.Data.tag("#{cx.program} approval", :cyan)
          ],
        title: " Next ",
        border_style: :solid_rounded,
        padding_x: 1,
        max_width: min(cx.terminal.width, 100),
        word_wrap: :normal
      )
    ])
  end

  defp to_run([]), do: []

  defp to_run(commands) do
    ["Run these yourself:\n"] ++
      Enum.flat_map(commands, fn {command, why} ->
        [Owl.Data.tag(command, :cyan), "\n", Owl.Data.tag(why, :light_black), "\n"]
      end) ++ ["\n"]
  end

  defp config(org, model, search?) do
    """
    # What the daemon reads as it starts. Restart it after a change.
    org: #{org}

    defaults:
      model: #{model}

    http:
      port: 4747

    # The assistant makes, changes, reads and asks the org's agents, its workers, and reads their
    # runs. It can't forget, clear, stop or cancel one. It reads and adds the org's MCP servers,
    # notify targets and OAuth apps, each change once a person approves it, and lists its
    # secrets by name.
    roles:
      workers:
        rules:
          - {verbs: [create, define, read, ask, events], kinds: [agent]}
          - {verbs: [read, add], kinds: [mcp_server, notify_target, provider]}
          - {verbs: [read], kinds: [secret]}
      # It reads the deployment's nodes, resource use and audit, to say how things run, and lists
      # the deployment's secrets by name.
      observer:
        rules:
          - {verbs: [nodes, runtime, audit], kinds: [deployment]}
          - {verbs: [read], kinds: [secret]}
    bindings:
      - {org: #{org}, role: workers, subjects: [agent:assistant]}
      - {org: deployment, role: observer, subjects: [agent:assistant]}

    # Orgs and people may add MCP servers and webhooks at public https URLs alone. For local
    # development, with servers on this machine or network, uncomment this. Never in production.
    # allow_private_urls: true

    """ <> brave(search?)
  end

  defp brave(true) do
    """
    # web_search searches the web through Brave with this key.
    brave:
      api_key: ${BRAVE_API_KEY}
    """
  end

  defp brave(false) do
    """
    # web_search searches the web through Brave. To turn it on, seal a key with
    # `wardrik vault put BRAVE_API_KEY --for api_key`, or set BRAVE_API_KEY in env and uncomment
    # these lines. Until then, the assistant says how.
    # brave:
    #   api_key: ${BRAVE_API_KEY}
    """
  end

  # Named reads in place of ops/read: each tool goes into every model call.
  @tools ~w(self/* agents/* agent_create ops/agent.runs ops/agent.timeline ops/agent.resolved
            ops/interrupts.list ops/deployment.runtime settings help files web_search run_lua)
  @listed Enum.join(@tools, ", ")

  @doc "Returns the tools the assistant `init` writes has. The doctor names any a file leaves out."
  @spec assistant_tools() :: [String.t()]
  def assistant_tools, do: @tools

  # Every 6 hours it checks how things run, and proposes what needs a person as the call that does
  # it, so it shows in approvals. Each check is a model call with its tools, tens of thousands of
  # tokens.
  defp assistant do
    """
    ---
    description: "Turns what people ask for into work that runs."
    tools: [#{@listed}]
    context: [MEMORY.md]
    policy: {budget: {tokens: 2000000, per: day}}
    idle_timeout: infinity
    triggers:
      - name: check
        every: 6h
        prompt: >-
          Check how things run: the runs of the workers you set up, calls that wait on a person,
          the doctor's checks, and each node's memory. For each problem a call of yours can fix,
          propose that call. Answer "All well." in one line when nothing needs a person.
    ---
    """ <> File.read!(Application.app_dir(:wardrik_daemon, "priv/front_door.md"))
  end

  defp env do
    """
    # Keys the daemon reads where its environment doesn't set them, one NAME=value a line.
    # ANTHROPIC_API_KEY=sk-ant-...
    # BRAVE_API_KEY=...
    """
  end
end
