defmodule Mix.Tasks.Tars do
  @shortdoc "Boot the Tars TUI"

  @default_tools [TarsBrave.WebSearch, TarsResearch.Deep]

  @moduledoc """
  Starts an agent and attaches the full-screen `TarsTUI.App` to it.

      mix tars
      mix tars --verbose
      mix tars --model anthropic:claude-sonnet-5
      mix tars --log /tmp/tars.log
      mix tars --tool TarsBrave.WebSearch --tool TarsResearch.Deep
      mix tars --no-tools
      mix tars --policy MyApp.Policy --user jon --org acme
      mix tars --timeout 600
      mix tars --name researcher --org acme
      mix tars --sname tars_a --cookie tars --connect tars_b@omarchy
      mix tars --fleet-width 36

  The agent boots with the tool packages this repo ships —
  `#{Enum.map_join(@default_tools, "`, `", &inspect/1)}` — because a turn with
  no tools exercises none of the tree. `--tool` names a different set, and
  `--no-tools` boots without any.

  `--policy` names a `Tars.Policy` module, and `--user` and `--org` say who the
  turn is for, which is what a policy reads to decide. A policy that answers
  `{:ask, prompt}` parks the turn; resume it from anywhere that can reach the
  node:

      Tars.Agent.resume("acme/jon/assistant", %{"call_abc" => :approve})

  `--timeout` bounds a whole turn, in seconds.

  `--name`, with `--org` and `--user`, is the agent's key in the fleet, and the
  fleet keeps an agent's conversation across restarts. Starting with the same
  three attaches to the same agent and shows what was said so far, which is how
  a session is resumed:

      mix tars --name researcher --org acme --user jon

  ## Clustering

  `--sname` names this node and `--cookie` sets its cookie, both before the
  application starts so the node has a data directory of its own. `--connect`
  names a peer to connect to, repeatable, and also runs first: the fleet's
  store counts its quorum over the peers already connected, so a node that
  joins afterwards is too late.

      mix tars --sname tars_b --cookie tars --connect tars_a@$hostname

  Agents started on either node appear in both, and `/connect` in the client
  attaches to one wherever it is running. `dev/cluster.sh` brings up three
  nodes in tmux.

  `--fleet-width` is the fleet panel's width in columns, #{TarsTUI.App.default_sidebar_width()}
  by default. The panel is dropped to an overlay on a terminal too narrow to
  hold it beside the transcript.

  `--verbose` adds a trace line for the lower-level events — model requests,
  tool calls, metadata — and commits the model's reasoning to the transcript.
  `Ctrl-T` toggles the same thing while running.

  Console logging is removed before the app starts: the client draws frames on
  the terminal, and any `Logger` write to the same device lands in the middle
  of one. Pass `--log FILE` (or set `TARS_LOG`) to keep the messages —
  without it, `Logger.error("Turn crashed: …")` goes nowhere.
  """

  use Mix.Task

  alias Tars.LLM

  @impl Mix.Task
  def run(argv) do
    {opts, _argv} =
      OptionParser.parse!(argv,
        strict: [
          model: :string,
          log: :string,
          verbose: :boolean,
          tool: :keep,
          tools: :boolean,
          policy: :string,
          user: :string,
          org: :string,
          name: :string,
          timeout: :integer,
          sname: :string,
          cookie: :string,
          connect: :keep,
          fleet_width: :integer
        ]
      )

    # Both before the application: the store is named after this node, and the
    # fleet's quorum is counted over the peers that are already connected.
    distribute(opts)
    Enum.each(Keyword.get_values(opts, :connect), &Node.connect(:"#{&1}"))

    Mix.Task.run("app.start")

    # After app.start, not before: starting the :logger application installs
    # the default handler, so removing it earlier is undone.
    silence_console_logging()
    redirect_logging(opts[:log] || System.get_env("TARS_LOG"))

    config = config(opts)
    spawn_opts = [config: config] ++ scope_opts(opts)
    agent_id = Tars.Fleet.key(opts[:name] || "assistant", spawn_opts)

    {:ok, _agent} = Tars.Fleet.spawn(agent_id, spawn_opts)

    :ok =
      Breeze.Server.run(
        view: TarsTUI.App,
        start_opts:
          [
            agent: agent_id,
            agent_id: agent_id,
            spawn_opts: spawn_opts,
            model: config.model_spec,
            verbose: opts[:verbose] || false
          ] ++ sidebar_width(opts),
        global_keybindings: TarsTUI.App.keybindings(),
        mouse: true,
        logger: false,
        inspector: false
      )
  end

  defp sidebar_width(opts) do
    case opts[:fleet_width] do
      nil -> []
      width -> [sidebar_width: width]
    end
  end

  defp distribute(opts) do
    if sname = opts[:sname] do
      {:ok, _pid} = Node.start(:"#{sname}@#{hostname()}", name_domain: :shortnames)
      if cookie = opts[:cookie], do: Node.set_cookie(:"#{cookie}")
    end
  end

  defp hostname, do: :inet.gethostname() |> elem(1) |> to_string()

  defp silence_console_logging, do: :logger.remove_handler(:default)

  defp redirect_logging(nil), do: :ok

  defp redirect_logging(path) do
    :ok = File.mkdir_p!(Path.dirname(path))

    :logger.add_handler(:tars_file, :logger_std_h, %{
      config: %{file: String.to_charlist(path)},
      formatter: {:logger_formatter, %{single_line: true}}
    })
  end

  defp config(opts) do
    opts
    |> Keyword.take([:model])
    |> Enum.map(fn {:model, spec} -> {:model_spec, spec} end)
    |> Keyword.put(:tools, tools(opts))
    |> LLM.Config.new()
  end

  # Only what was actually given: an agent started with no policy and no
  # deadline should look exactly as it did before either existed.
  defp scope_opts(opts) do
    opts
    |> Keyword.take([:user, :org])
    |> put_new_option(:policy, opts[:policy], &Module.safe_concat([&1]))
    |> put_new_option(:timeout, opts[:timeout], &:timer.seconds/1)
  end

  defp put_new_option(opts, _key, nil, _cast), do: opts
  defp put_new_option(opts, key, value, cast), do: Keyword.put(opts, key, cast.(value))

  defp tools(opts) do
    if Keyword.get(opts, :tools, true), do: named(Keyword.get_values(opts, :tool)), else: []
  end

  defp named([]), do: @default_tools
  defp named(names), do: Enum.map(names, &Module.safe_concat([&1]))
end
