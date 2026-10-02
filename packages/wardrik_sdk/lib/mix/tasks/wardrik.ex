defmodule Mix.Tasks.Wardrik do
  @shortdoc "Boot the Wardrik TUI"

  @default_tools [WardrikBrave.WebSearch, WardrikResearch.Deep]

  @moduledoc """
  Starts an agent and attaches the full-screen `WardrikTUI.App` to it.

      mix wardrik
      mix wardrik --verbose
      mix wardrik --model anthropic:claude-sonnet-5
      mix wardrik --log /tmp/wardrik.log
      mix wardrik --tool WardrikBrave.WebSearch --tool WardrikResearch.Deep
      mix wardrik --no-tools
      mix wardrik --mcp github --mcp linear
      mix wardrik --policy MyApp.Policy --user jon --org acme
      mix wardrik --timeout 600
      mix wardrik --name researcher --org acme
      mix wardrik --sname wardrik_a --cookie wardrik --connect wardrik_b@omarchy
      mix wardrik --fleet-width 36

  The agent boots with the tool packages this repo ships —
  `#{Enum.map_join(@default_tools, "`, `", &inspect/1)}` — because a turn with
  no tools exercises none of the tree. `--tool` names a different set, and
  `--no-tools` boots without any.

  Unnamed, the agent takes every MCP server connected on the node, as they
  stand each turn: one that connects, reconnects, or says its tools changed
  while the agent runs is picked up without restarting it. `--mcp` narrows that
  to the servers it names, from `config :wardrik, WardrikMCP`, and is repeatable. An
  agent given `--tool` takes only what it names, so the servers an agent with a
  tool set of its own reaches are the ones `--mcp` names beside it.

  What a server writes to its own stderr goes to `--log`, or nowhere: it would
  otherwise land on the frame this client is drawing. The servers start with
  the node, so a server that is slow to answer costs the agent only the tools
  it has not listed yet. See `WardrikMCP` for the configuration, including how a
  token reaches a server.

  `--credentials` names a `Wardrik.Credential` module. Unnamed, the agent gets
  `WardrikVault` where the vault has a key, and none otherwise. A tool that needs
  a credential the user has not authorized parks the turn on a link; open it,
  then answer `y` to run the call again.

  `--policy` names a `Wardrik.Hook` module, and `--user` and `--org` say who the
  turn is for, which is what a hook reads to decide. A hook that asks about a call
  parks the turn; resume it from anywhere that can reach the
  node:

      Wardrik.Agent.resume("acme/@jon/assistant", %{"call_abc" => :approve})

  `--timeout` bounds a whole turn, in seconds.

  `--name`, with `--org` and `--user`, is the agent's key in the fleet, and the
  fleet keeps an agent's conversation across restarts. Starting with the same
  three attaches to the same agent and shows what was said so far, which is how
  a session is resumed:

      mix wardrik --name researcher --org acme --user jon

  ## Clustering

  `--sname` names this node and `--cookie` sets its cookie, both before the
  application starts so the node has a data directory of its own. `--connect`
  names a peer to connect to, repeatable, and also runs first: the fleet's
  store counts its quorum over the peers already connected, so a node that
  joins afterwards is too late.

      mix wardrik --sname wardrik_b --cookie wardrik --connect wardrik_a@$hostname

  Agents started on either node appear in both, and `/connect` in the client
  attaches to one wherever it is running. `dev/cluster.sh` brings up three
  nodes in tmux.

  `--fleet-width` is the fleet panel's width in columns, #{WardrikTUI.App.default_sidebar_width()}
  by default. The panel is dropped to an overlay on a terminal too narrow to
  hold it beside the transcript.

  `--verbose` adds a trace line for the lower-level events — model requests,
  tool calls, metadata — and commits the model's reasoning to the transcript.
  `Ctrl-T` toggles the same thing while running.

  Console logging is removed before the app starts: the client draws frames on
  the terminal, and any `Logger` write to the same device lands in the middle
  of one. Pass `--log FILE` (or set `WARDRIK_LOG`) to keep the messages —
  without it, `Logger.error("Turn crashed: …")` goes nowhere.
  """

  use Mix.Task

  alias Wardrik.LLM.Config

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
          mcp: :keep,
          policy: :string,
          credentials: :string,
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

    start_mcp(opts)
    start_oauth()

    # After app.start, not before: starting the :logger application installs
    # the default handler, so removing it earlier is undone.
    silence_console_logging()
    redirect_logging(opts[:log] || System.get_env("WARDRIK_LOG"))

    config = config(opts)
    spawn_opts = [config: config] ++ scope_opts(opts)
    agent_id = Wardrik.Fleet.key(opts[:name] || "assistant", spawn_opts)

    {:ok, _agent} = Wardrik.Fleet.spawn(agent_id, spawn_opts)

    :ok =
      Breeze.Server.run(
        WardrikTUI.App.server_opts(
          [
            agent: agent_id,
            agent_id: agent_id,
            spawn_opts: spawn_opts,
            model: config.model_spec,
            verbose: opts[:verbose] || false
          ] ++ sidebar_width(opts)
        )
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

    :logger.add_handler(:wardrik_file, :logger_std_h, %{
      config: %{file: String.to_charlist(path)},
      formatter: {:logger_formatter, %{single_line: true}}
    })
  end

  defp config(opts) do
    opts
    |> Keyword.take([:model])
    |> Enum.map(fn {:model, spec} -> {:model_spec, spec} end)
    |> Keyword.put(:tools, tools(opts))
    |> Config.new()
  end

  # Only what was actually given: an agent started with no policy and no
  # deadline should look exactly as it did before either existed.
  defp scope_opts(opts) do
    opts
    |> Keyword.take([:user, :org])
    |> put_new_option(
      :hooks,
      opts[:policy],
      &[Wardrik.Hook.new(&1, Module.safe_concat([&1]))]
    )
    |> put_new_option(:credentials, credentials(opts), & &1)
    |> put_new_option(:timeout, opts[:timeout], &:timer.seconds/1)
  end

  defp put_new_option(opts, _key, nil, _cast), do: opts
  defp put_new_option(opts, key, value, cast), do: Keyword.put(opts, key, cast.(value))

  defp tools(opts) do
    if Keyword.get(opts, :tools, true) do
      named(Keyword.get_values(opts, :tool)) ++ mcp_sources(opts)
    else
      []
    end
  end

  defp named([]), do: @default_tools
  defp named(names), do: Enum.map(names, &Module.safe_concat([&1]))

  # Unnamed, the agent takes whatever is connected, read again every turn.
  defp mcp_sources(opts) do
    configured = WardrikMCP.Config.refs()

    case Keyword.get_values(opts, :mcp) do
      [] -> ambient(opts)
      names -> for name <- names, do: {WardrikMCP, configured!(configured, name)}
    end
  end

  # `--tool` is a tool set, not an addition to one: an agent given it reaches
  # the servers named beside it and no others.
  defp ambient(opts), do: if(Keyword.has_key?(opts, :tool), do: [], else: [{WardrikMCP, :*}])

  defp configured!(configured, name) do
    Enum.find(configured, fn ref -> to_string(ref) == name end) ||
      Mix.raise(
        "no MCP server is configured as #{name}; config :wardrik, WardrikMCP has " <>
          Enum.map_join(configured, ", ", &to_string/1)
      )
  end

  # The MCP servers are the host's to run, not core's, and an agent naming one
  # is valid whether or not it is up.
  defp start_mcp(opts) do
    if Keyword.has_key?(opts, :mcp) or WardrikMCP.configured?() do
      {:ok, _pid} = WardrikMCP.Supervisor.start_link(stderr: server_stderr(opts))
    end
  end

  # A command started for an MCP server inherits this terminal, and the client
  # is drawing on it. Its output goes to the log file, or nowhere.
  defp server_stderr(opts) do
    case opts[:log] || System.get_env("WARDRIK_LOG") do
      nil -> :discard
      path -> {:file, path}
    end
  end

  defp start_oauth do
    if WardrikOAuth.Config.configured?(), do: {:ok, _pid} = WardrikOAuth.Supervisor.start_link()
  end

  # The vault, where it can unseal, so a deployment that keyed one does not
  # also have to name it.
  defp credentials(opts) do
    cond do
      opts[:credentials] -> Module.safe_concat([opts[:credentials]])
      WardrikVault.ready?() -> WardrikVault
      true -> nil
    end
  end
end
