defmodule WardrikDaemon.CLI.Init do
  @moduledoc """
  `wardrik init`: from a fresh install to a front door that has answered once. It says what it does
  as it goes:

    1. the model providers whose key this environment sets.
    2. the provider, those with a key here first, and the model: `claude-haiku-4-5` for Anthropic,
       or else the provider's newest.
    3. the provider's key, read without showing it, unless the env file or the environment sets
       it.
    4. the files, keeping any already there:
       * `config.yaml` - with the org and the default model.
       * `agents/assistant.md` - the front door.
       * `env` - for the keys `config.yaml` names. Only you can read it.
    5. the daemon: run as a systemd user service where there's one, as `wardrik service install`
       does, or else started with `wardrik start`. One already running reads a new agent file.
    6. the key, sealed in the vault as the deployment's secret, unless the env file sets it.
    7. the front door, asked one short question.

  Without a terminal, flags answer: `--provider`, `--model` and `--key-from-env VAR`, and `--yes`
  runs the daemon as a service. `--no-service` starts it without systemd, and `--no-ask` asks the
  front door nothing.

  The front door is the agent you tell an outcome, as "tell me when this feed has a new post". It
  proposes the work as the calls that do it, and defines the workers once you approve them. It
  keeps what it set up in its `MEMORY.md`. Its body is its instructions, then a playbook to edit as
  you like. It searches the web with `web_search` where `BRAVE_API_KEY` is set. Elsewhere
  `config.yaml` says how to turn it on.
  """

  alias WardrikDaemon.CLI.Access
  alias WardrikDaemon.CLI.Command
  alias WardrikDaemon.CLI.Context
  alias WardrikDaemon.CLI.Follow
  alias WardrikDaemon.CLI.Terminal
  alias WardrikDaemon.Dirs
  alias WardrikDaemon.EnvFile

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
        no_ask: :boolean
      ],
      summary: "set up the front door, its model and key, and the daemon to run it",
      details: [
        "It asks what it needs, says what it does, and writes no file that's already there.",
        "Without a terminal, --provider, --model and --key-from-env VAR answer, and --yes runs",
        "the daemon as a systemd service. --no-service starts it without systemd, and --no-ask",
        "asks the front door nothing. --org names the org, default unless set."
      ],
      run: &run/3
    }
  end

  defp run([], flags, cx) do
    found(cx)

    with {:ok, provider, variable} <- provider(flags, cx),
         {:ok, model} <- model(flags, cx, provider),
         {:ok, key} <- key(flags, cx, variable) do
      wrote = write(cx, flags, "#{provider}:#{model}")
      cx = %{Context.new(cx.env) | terminal: cx.terminal}

      with :ok <- daemon(flags, cx, wrote, key != nil or flags[:no_ask] != true),
           :ok <- sealed(cx, variable, key),
           :ok <- ask(flags, cx, variable) do
        next(cx)
      end
    end
  end

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
          "No key, so the front door can't answer until #{cx.program} vault put #{variable} --for api_key seals one."
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
            {"agents/assistant.md", assistant(search?), 0o644},
            {"env", env(), 0o600}
          ],
          written?(cx, Dirs.config(cx.dirs, name), text, mode),
          do: name

    unless "config.yaml" in wrote or modelled?(cx.dirs),
      do:
        Context.puts(
          cx,
          "config.yaml names no default model, so the front door has none. Add it:\n" <>
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
      Context.puts(cx, [Owl.Data.tag("Kept ", :light_black), " ", path])
      false
    else
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
      File.chmod!(path, mode)
      Context.puts(cx, [Owl.Data.tag("Wrote", :green), " ", path])
      true
    end
  end

  defp daemon(flags, cx, wrote, needed?) do
    case Context.call(cx, "deployment.nodes", %{}) do
      {:ok, _nodes} -> running(cx, wrote)
      {:error, _down} -> started(flags, cx, needed?)
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
      {_output, 0} -> if needed?, do: answering(cx, 60), else: :ok
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

  defp answering(cx, 0),
    do: {:error, "The daemon didn't answer. See what it logs: #{cx.program} logs"}

  defp answering(cx, tries) do
    case Context.call(cx, "deployment.nodes", %{}) do
      {:ok, _nodes} ->
        :ok

      {:error, _starting} ->
        Process.sleep(1_000)
        answering(cx, tries - 1)
    end
  end

  defp sealed(_cx, _variable, nil), do: :ok

  defp sealed(cx, variable, key),
    do: Access.seal(cx, owner: "deployment", name: variable, value: key, purpose: "api_key")

  defp ask(%{no_ask: true}, _cx, _variable), do: :ok

  defp ask(_flags, cx, variable) do
    Context.puts(cx, "Asking the front door: #{@question}")

    answered =
      with {:ok, id} <- Context.agent(cx, "assistant"),
           do: Follow.turn(cx, agent: id, name: "assistant", text: @question)

    case answered do
      :ok ->
        :ok

      {:error, why} ->
        {:error,
         "The front door didn't answer: #{why} The usual reason is its key, which " <>
           "#{cx.program} vault put #{variable} --for api_key seals again."}
    end
  end

  defp next(cx) do
    Context.puts(cx, """

    Next, tell it what you want done:
      #{cx.program} ask assistant "Tell me when https://elixir-lang.org/atom.xml has a new post"
    It proposes the work, and waits for you: #{cx.program} approval ls, then #{cx.program} approval approve.\
    """)
  end

  defp config(org, model, search?) do
    """
    # What the daemon reads as it starts. Restart it after a change.
    org: #{org}

    defaults:
      model: #{model}

    http:
      port: 4747

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
    # web_search searches the web through Brave. To turn it on, set BRAVE_API_KEY in env or seal it
    # with `wardrik vault put BRAVE_API_KEY --for api_key`, uncomment these lines, and add web_search to the tools
    # in agents/assistant.md.
    # brave:
    #   api_key: ${BRAVE_API_KEY}
    """
  end

  defp assistant(search?) do
    tools =
      if search?,
        do: "self/*, agents/*, files, web_search, run_lua",
        else: "self/*, agents/*, files, run_lua"

    """
    ---
    description: "The front door: turns what people ask for into work that runs."
    tools: [#{tools}]
    context: [MEMORY.md]
    policy: {budget: {tokens: 2000000, per: day}}
    idle_timeout: infinity
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
